#!/usr/bin/env python3

# This file is part of INAV.
#
# author of the original Ruby implementation:
#   Alberto Garcia Hierro <alberto@garciahierro.com>
# Python port for the iNavgke standalone offline build.
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Alternatively, the contents of this file may be used under the terms
# of the GNU General Public License Version 3, as described below:
#
# This file is free software: you may copy, redistribute and/or modify
# it under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This file is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see http://www.gnu.org/licenses/.
#
# This is a line-by-line port of src/utils/settings.rb and is intended to
# produce equivalent `settings_generated.h` / `settings_generated.c` without
# requiring Ruby. The only behavioural change is condition detection, which
# uses `#warning` markers instead of `#pragma message` (GCC 15 changed the
# format '#'pragma message' output, breaking the original regex).

import argparse
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit(
        "PyYAML is required to run settings.py (pip install pyyaml). "
        "It is part of the offline iNavgke toolchain."
    )

DEBUG = False
INFO = False

SETTINGS_WORDS_BITS_PER_CHAR = 5

_SYMBOL_RE = re.compile(r"^:[A-Za-z_][A-Za-z0-9_]*$")


def dputs(s):
    if DEBUG:
        print(s)


class Symbol:
    """Stand-in for a Ruby Symbol (:zero, :target)."""

    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name

    def __eq__(self, other):
        return isinstance(other, Symbol) and other.name == self.name

    def __hash__(self):
        return hash(("symbol", self.name))

    def __repr__(self):
        return ":" + self.name

    def __str__(self):
        return self.name


def is_number_kind(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_number_string(v):
    if not isinstance(v, str):
        return False
    try:
        float(v)
        return True
    except ValueError:
        return False


def ruby_to_i(v):
    """Emulate Ruby's String#to_i for the `values << v.to_i` call."""
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    s = str(v).lstrip()
    m = re.match(r"[+-]?\d+", s)
    if not m:
        return 0
    return int(m.group(0))


def ruby_float_to_s(f):
    """Best-effort emulation of Ruby's Float#to_s."""
    f = float(f)
    s = repr(f)
    if "e" in s or "E" in s:
        mant, _, exp = s.partition("e")
        exp = int(exp)
        if "." not in mant:
            mant += ".0"
        return "%se%s%02d" % (mant, "+" if exp >= 0 else "-", abs(exp))
    if "." not in s:
        s += ".0"
    return s


def rb_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def rb_inspect(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, Symbol):
        return ":" + v.name
    if isinstance(v, float):
        return ruby_float_to_s(v)
    if isinstance(v, str):
        return rb_str(v)
    return str(v)


def carr(values):
    """Emulate StringIO#to_carr: [1, 2, 3] -> "{1, 2, 3}"."""
    return "{" + ", ".join(str(v) for v in values) + "}"


def shl(value, bits):
    """Ruby's `x << n` which shifts right for negative n."""
    if bits >= 0:
        return value << bits
    return value >> (-bits)


def _convert_symbols(obj):
    if isinstance(obj, dict):
        return {k: _convert_symbols(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_convert_symbols(v) for v in obj]
    if isinstance(obj, str) and _SYMBOL_RE.match(obj):
        return Symbol(obj[1:])
    return obj


class Compiler:
    def __init__(self, use_host_gcc):
        dirs = (
            (os.environ.get("CPP_PATH", "") or "")
            + os.pathsep
            + (os.environ.get("PATH", "") or "")
        ).split(os.pathsep)
        binary = os.environ.get("SETTINGS_CXX") or ""
        if not binary:
            binary = "g++" if use_host_gcc else "arm-none-eabi-g++"
        self.verbose = os.environ.get("V") == "1"
        self.path = None
        for d in dirs:
            if not d:
                continue
            for suffix in ("", ".exe"):
                candidate = os.path.expanduser(os.path.join(d, binary + suffix))
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    if self.verbose:
                        print("Found %s at %s" % (binary, candidate))
                    self.path = candidate
                    break
            if self.path:
                break
        if not self.path:
            raise RuntimeError(
                "Could not find %s in PATH, looked in %s" % (binary, dirs)
            )

    def default_args(self):
        cflags = shlex.split(os.environ.get("CFLAGS", "") or "")
        args = [self.path, "-std=c++11"]
        for flag in cflags:
            if flag == "" or flag == "-MMD" or flag == "-MP":
                continue
            if flag.startswith("-save-temps"):
                continue
            if flag == "-Wstrict-prototypes":
                continue
            if flag.startswith("-std="):
                continue
            if flag.startswith("-D'"):
                flag = "-D" + flag[3:-2]
            args.append(flag)
        return args

    def run(self, input_file, output, args=None, noerror=False):
        all_args = self.default_args()
        if args:
            all_args.extend(args)
        if output:
            all_args.append("-o")
            all_args.append(output)
        all_args.append(input_file)
        proc = subprocess.run(all_args, capture_output=True, text=True)
        if not noerror and proc.returncode != 0:
            raise RuntimeError(
                "Compiler error:\n%s\n%s" % (" ".join(all_args), proc.stderr)
            )
        return proc.stdout, proc.stderr


class NameEncoder:
    def __init__(self, names, max_length):
        self.names = names
        self.max_length = max_length
        self.words_hash = {}
        self.words_by_usage = []
        self.non_split = set()
        self.encoded = {}
        self.max_word_length = 0

        self.update_words()
        self.encode_names()

    def uses_byte_indexing(self):
        return len(self.words_hash) < 255

    @property
    def words(self):
        return self.words_by_usage

    def estimated_size(self, settings_count):
        size = 0
        self.max_word_length = 0
        for word, _count in self.words_hash.items():
            size += (len(word) + 1) * (5 / 8.0)
            if len(word) > self.max_word_length:
                self.max_word_length = len(word)
        return int(size) + self.max_length * settings_count

    def format_encoded_name(self, name):
        encoded = self.encoded.get(name)
        if encoded is None:
            raise RuntimeError("Name %s was not encoded" % name)
        return carr(encoded)

    def split_words(self, name):
        if name in self.non_split:
            return [name]
        return name.split("_")

    def update_words(self):
        self.words_hash = {}
        for name in self.names:
            for word in self.split_words(name):
                self.words_hash[word] = self.words_hash.get(word, 0) + 1
        self.words_by_usage = sorted(
            self.words_hash.keys(), key=lambda w: (-self.words_hash[w], w)
        )

    def encode_names(self):
        self.encoded = {}
        for name in self.names:
            buf = bytearray()
            for word in self.split_words(name):
                try:
                    pos = self.words_by_usage.index(word)
                except ValueError:
                    raise RuntimeError("Word %s not found in words array" % word)
                p = pos + 1
                if self.uses_byte_indexing():
                    buf.append(p)
                else:
                    self.write_uvarint(buf, p)
            if len(buf) > self.max_length:
                self.non_split.add(name)
                self.update_words()
                return self.encode_names()
            while len(buf) < self.max_length:
                buf.append(0)
            self.encoded[name] = bytes(buf)

    @staticmethod
    def write_uvarint(buf, x):
        while x >= 0x80:
            buf.append((x & 0xFF) | 0x80)
            x >>= 7
        buf.append(x)


class ValueEncoder:
    def __init__(self, values, constants):
        minimum = 0
        maximum = 0
        counts = {}
        for v in values:
            minimum = min(minimum, v)
            maximum = max(maximum, v)
            counts[v] = counts.get(v, 0) + 1
        self.values = sorted(counts.keys(), key=lambda v: (-counts[v], v))
        self.constants = constants
        self.min = minimum
        self.max = maximum

    def min_type(self):
        for bits in (8, 16, 32):
            if self.min >= -(2 ** (bits - 1)):
                return "int%d_t" % bits
        raise RuntimeError("cannot represent minimum value %s with int32_t" % self.min)

    def max_type(self):
        for bits in (8, 16, 32):
            if self.max < 2 ** bits:
                return "uint%d_t" % bits
        raise RuntimeError("cannot represent maximum value %s with uint32_t" % self.max)

    def index_bytes(self):
        bits = math.ceil(math.log2(len(self.values))) if len(self.values) > 1 else 0
        bytes_ = int(math.ceil(bits / 8.0))
        if bytes_ > 1:
            raise RuntimeError("too many bytes required for value index: %d" % bytes_)
        return bytes_

    def encode_values(self, minimum, maximum):
        buf = bytearray()
        self.encode_value(buf, minimum)
        self.encode_value(buf, maximum)
        return carr(buf)

    def resolve_value(self, val):
        v = val if val not in (None, False) else 0
        if not is_number_kind(v):
            v = self.constants.get(val)
            if v is None:
                raise RuntimeError("Could not resolve constant %s" % val)
        return v

    def encode_value(self, buf, val):
        v = self.resolve_value(val)
        try:
            pos = self.values.index(v)
        except ValueError:
            raise RuntimeError("Could not encode value not in array %s" % v)
        buf.append(pos)


OFF_ON_TABLE = {"name": "off_on", "values": ["OFF", "ON"]}


class Generator:
    def __init__(self, src_root, settings_file, output_dir, use_host_gcc):
        self.src_root = src_root
        self.settings_file = settings_file
        self.output_dir = output_dir or os.path.dirname(settings_file)

        self.compiler = Compiler(use_host_gcc)

        self.count = 0
        self.max_name_length = 0
        self.tables = {}
        self.used_tables = set()
        self.enabled_tables = set()
        self.true_conditions = set()
        self.data = None
        self.constants = {}
        self.name_encoder = None
        self.value_encoder = None

    # ---- top level --------------------------------------------------------

    def write_files(self):
        for path in (self.header_file(), self.impl_file()):
            if os.path.isfile(path):
                os.remove(path)

        self.load_data()

        self.check_member_default_values_presence()
        self.sanitize_fields()
        self.resolv_min_max_and_default_values_if_possible()
        self.initialize_name_encoder()
        self.initialize_value_encoder()
        self.validate_default_values()

        self.write_header_file(self.header_file())
        self.write_impl_file(self.impl_file())

    def write_json(self, json_file):
        self.load_data()
        self.sanitize_fields(True)

        settings = {}
        for group, member in self.iter_members():
            name = member["name"]
            s = {"type": member["type"]}
            table = member.get("table")
            if table:
                s["table"] = self.tables[table]
            settings[name] = s

        with open(json_file, "w") as f:
            f.write(json.dumps(settings, indent=2))

    def print_stats(self):
        print("%d settings" % self.count)
        print("words table has %d words" % len(self.name_encoder.words))
        word_idx = "byte" if self.name_encoder.uses_byte_indexing() else "uvarint"
        print("name encoder uses %s word indexing" % word_idx)
        print("each setting name uses %d bytes" % self.name_encoder.max_length)
        print(
            "%d bytes estimated for setting name storage"
            % self.name_encoder.estimated_size(self.count)
        )
        values_size = len(self.value_encoder.values) * 4
        print("min/max value storage uses %d bytes" % values_size)
        value_idx_size = self.value_encoder.index_bytes() * 2
        value_idx_total = value_idx_size * self.count
        print(
            "value indexing uses %d per setting, %d bytes total"
            % (value_idx_size, value_idx_total)
        )
        print(
            "%d bytes estimated for value+indexes storage"
            % (value_idx_size + value_idx_total)
        )

        buf = []
        buf.append('#include "fc/settings.h"\n')
        buf.append("char (*dummy)[sizeof(setting_t)] = 1;\n")
        stderr = self.compile_test_file("".join(buf))
        m = re.search(r"char \(\*\)\[(\d+)\]", stderr)
        print("sizeof(setting_t) = %s" % m.group(1))

    # ---- data loading -----------------------------------------------------

    def header_file(self):
        return os.path.join(self.output_dir, "settings_generated.h")

    def impl_file(self):
        return os.path.join(self.output_dir, "settings_generated.c")

    def load_data(self):
        with open(self.settings_file, "r") as f:
            self.data = _convert_symbols(yaml.safe_load(f))

        self.initialize_tables()
        self.initialize_constants()
        self.check_conditions()

    def initialize_tables(self):
        for tbl in self.data["tables"]:
            name = tbl["name"]
            if name in self.tables:
                raise RuntimeError("Duplicate table name %s" % name)
            self.tables[name] = tbl

    def initialize_constants(self):
        self.constants = self.data.get("constants") or {}

    @property
    def groups(self):
        return self.data["groups"]

    def iter_members(self):
        for group in self.groups:
            for member in group["members"]:
                yield group, member

    def is_condition_enabled(self, cond):
        return (not cond) or (cond in self.true_conditions)

    def iter_enabled_members(self):
        for group in self.groups:
            if self.is_condition_enabled(group.get("condition")):
                for member in group["members"]:
                    if self.is_condition_enabled(member.get("condition")):
                        yield group, member

    def iter_enabled_groups(self):
        last = None
        for group, _member in self.iter_enabled_members():
            if last is not group:
                last = group
                yield group

    @staticmethod
    def wrap_condition(condition):
        buf = []
        in_word = False
        for ch in condition:
            if in_word:
                if not re.match(r"[a-zA-Z0-9_]", ch):
                    in_word = False
                    buf.append(")")
                buf.append(ch)
            else:
                if re.match(r"[a-zA-Z_]", ch):
                    in_word = True
                    buf.append("defined(")
                buf.append(ch)
        if in_word:
            buf.append(")")
        return "".join(buf)

    def check_conditions(self):
        conditions = []
        seen = set()
        for group, member in self.iter_members():
            for cond in (group.get("condition"), member.get("condition")):
                if cond and cond not in seen:
                    seen.add(cond)
                    conditions.append(cond)

        lines = []
        for i, cond in enumerate(conditions):
            lines.append("#if " + self.wrap_condition(cond))
            lines.append("#warning INAV_COND_%d" % i)
            lines.append("#endif")
        prog = "\n".join(lines) + "\n"
        stderr = self.compile_test_file(prog)
        self.true_conditions = set()
        for m in re.finditer(r"INAV_COND_(\d+)", stderr):
            self.true_conditions.add(conditions[int(m.group(1))])

    # ---- compiler probing -------------------------------------------------

    def mktmpdir(self, func):
        tmp = os.path.join(self.output_dir, "tmp")
        os.makedirs(tmp, exist_ok=True)
        try:
            return func(tmp)
        finally:
            if os.path.isdir(tmp):
                shutil.rmtree(tmp, ignore_errors=True)

    def compile_test_file(self, prog):
        headers = ["platform.h", "cstddef"]
        for group in self.groups:
            gh = group.get("headers")
            if gh:
                headers.extend(gh)

        buf = []
        for h in headers:
            if h:
                buf.append('#include "%s"\n' % h)
        buf.append("\n")
        buf.append(prog)
        content = "".join(buf)

        def run_tmp(dirpath):
            filepath = os.path.join(dirpath, "test.cpp")
            with open(filepath, "w") as f:
                f.write(content)
            dputs("Compiling %s" % content)
            _stdout, stderr = self.compiler.run(
                filepath, os.path.join(dirpath, "test"), ["-c"], noerror=True
            )
            dputs("Output: %s" % stderr)
            return stderr

        return self.mktmpdir(run_tmp)

    def can_use_byte_offsetof(self):
        buf = []
        for group, member in self.iter_enabled_members():
            typ = group["type"]
            field = member["field"]
            buf.append(
                'static_assert(offsetof(%s, %s) < 255, "%s.%s is too big");\n'
                % (typ, field, typ, field)
            )
        stderr = self.compile_test_file("".join(buf))
        return "static assertion failed" not in stderr

    # ---- sanitizing / type resolution ------------------------------------

    def sanitize_fields(self, all_fields=False):
        pending_types = {}
        has_booleans = [False]

        def block(group, member):
            if not group.get("name"):
                raise RuntimeError("Missing group name")
            if not member.get("name"):
                raise RuntimeError("Missing member name in group %s" % group["name"])

            table = member.get("table")
            if table:
                if table not in self.tables:
                    raise RuntimeError(
                        "Member %s references non-existing table %s"
                        % (member["name"], table)
                    )
                self.used_tables.add(table)

            if not member.get("field"):
                member["field"] = member["name"]

            if member.get("type") == "bool":
                has_booleans[0] = True
                member["table"] = OFF_ON_TABLE["name"]

        if all_fields:
            for group, member in self.iter_members():
                block(group, member)
        else:
            for group, member in self.iter_enabled_members():
                block(group, member)

        if has_booleans[0]:
            self.tables[OFF_ON_TABLE["name"]] = OFF_ON_TABLE
            self.used_tables.add(OFF_ON_TABLE["name"])

        self.resolve_all_types()

        for _group, member in self.iter_enabled_members():
            self.count += 1
            self.max_name_length = max(self.max_name_length, len(member["name"]))
            if member.get("table"):
                self.enabled_tables.add(member["table"])

    def scan_types(self, stderr):
        types = {}
        for m in re.finditer(
            r"var_(\d+).*?['’], which is of non-class type ['‘](.*)['’]", stderr
        ):
            types[int(m.group(1))] = m.group(2)
        for m in re.finditer(
            r"member reference base type '(.*?)'.*?is not a structure or union.*? var_(\d+)",
            stderr,
            re.S,
        ):
            types[int(m.group(2))] = m.group(1)
        return types

    def resolve_all_types(self):
        while True:
            pending = []
            for group, member in self.iter_enabled_members():
                if not member.get("type"):
                    pending.append((member, group))
            if not pending:
                break
            self.resolve_types(pending)

    def resolve_types(self, pending):
        prog = []
        prog.append("int main() {\n")
        ii = 0
        members = {}
        for member, group in pending:
            var = "var_%d" % ii
            members[ii] = member
            ii += 1
            prog.append(
                "%s %s; %s.%s.__type_detect_;\n" % (group["type"], var, var, member["field"])
            )
        prog.append("return 0;\n")
        prog.append("};\n")
        stderr = self.compile_test_file("".join(prog))
        types = self.scan_types(stderr)
        if not types:
            raise RuntimeError("No types resolved from %s" % stderr)

        for idx, type_name in types.items():
            member = members[idx]
            if type_name.startswith("bool"):
                typ = "bool"
            elif type_name.startswith("int8_t"):
                typ = "int8_t"
            elif type_name.startswith("uint8_t"):
                typ = "uint8_t"
            elif type_name.startswith("int16_t"):
                typ = "int16_t"
            elif type_name.startswith("uint16_t"):
                typ = "uint16_t"
            elif type_name.startswith("uint32_t"):
                typ = "uint32_t"
            elif type_name == "float":
                typ = "float"
            else:
                m = re.match(r"^char\s*\[(\d+)\]", type_name)
                if m:
                    member["max"] = int(m.group(1)) - 1
                    typ = "string"
                else:
                    raise RuntimeError(
                        "Unknown type %s when resolving type for setting %s"
                        % (type_name, member["name"])
                    )
            dputs("%s type is %s" % (member["name"], typ))
            member["type"] = typ

    # ---- value resolution -------------------------------------------------

    def resolve_constants(self, constants):
        if not constants:
            return None
        unresolved = set(constants)
        dputs("%d constants to resolve" % len(constants))
        gcc_re = re.compile(r"required from ['‘]class expr_(.*?)<(.*?)>['’]")
        clang_re = re.compile(r"template class 'expr_(.*?)<(.*?)>'")
        values = {}
        while unresolved:
            buf = []
            buf.append("template <int64_t V> class Fail {\n")
            buf.append('static_assert(V == 42 && 0 == 1, "FAIL");\n')
            buf.append("public:\n")
            buf.append("Fail() {};\n")
            buf.append("int64_t v = V;\n")
            buf.append("};\n")
            for ii, c in enumerate(unresolved):
                cls = "expr_%s" % c
                buf.append("template <int64_t V> class %s: public Fail<V> {};\n" % cls)
                buf.append("%s<%s> var_%d;\n" % (cls, c, ii))
            stderr = self.compile_test_file("".join(buf))
            matches = []
            for regex in (gcc_re, clang_re):
                matches = regex.findall(stderr)
                if matches:
                    break
            if not matches:
                print(stderr)
                raise RuntimeError("No more matches looking for constants")
            for c, v in matches:
                v = v.replace("u", "").replace("l", "")
                nv = ruby_to_i(v)
                values[c] = nv
                unresolved.discard(c)
                dputs("Constant %s resolved to %d" % (c, nv))
        return values

    def initialize_value_encoder(self):
        values = []
        constants = []

        def add_value(v):
            v = v if v not in (None, False) else 0
            if is_number_kind(v) or (isinstance(v, str) and is_number_string(v)):
                values.append(ruby_to_i(v))
            else:
                constants.append(v)

        for _group, member in self.iter_enabled_members():
            add_value(member.get("min"))
            add_value(member.get("max"))

        constant_values = self.resolve_constants(constants)
        for c in constants:
            values.append(constant_values[c])

        self.value_encoder = ValueEncoder(values, constant_values)

    def resolve_range(self, member):
        minimum = self.value_encoder.resolve_value(member.get("min"))
        maximum = self.value_encoder.resolve_value(member.get("max"))
        return minimum, maximum

    def initialize_name_encoder(self):
        names = []
        for _group, member in self.iter_enabled_members():
            names.append(member["name"])
        best = None
        for v in range(3, 8):
            enc = NameEncoder(names, v)
            if best is None or best.estimated_size(self.count) > enc.estimated_size(self.count):
                best = enc
        dputs("Using name encoder with max_length = %d" % best.max_length)
        self.name_encoder = best

    # ---- validation -------------------------------------------------------

    def check_member_default_values_presence(self):
        missing = [
            member["name"]
            for _group, member in self.iter_members()
            if "default_value" not in member
        ]
        if missing:
            raise RuntimeError(
                "Missing default value for %d member%s: %s"
                % (len(missing), "" if len(missing) == 1 else "s", ", ".join(missing))
            )

    def resolv_min_max_and_default_values_if_possible(self):
        for _group, member in self.iter_members():
            for key in ("min", "max", "default_value"):
                value = member.get(key)
                if isinstance(value, str):
                    constant_value = self.constants.get(value)
                    if constant_value is not None:
                        member[key] = constant_value

    def validate_default_values(self):
        for _group, member in self.iter_enabled_members():
            name = member["name"]
            typ = member["type"]
            minimum = member.get("min") or 0
            maximum = member.get("max")
            default_value = member.get("default_value")

            if isinstance(default_value, Symbol) and default_value.name in ("zero", "target"):
                continue

            if typ == "bool":
                if default_value not in (False, True):
                    raise RuntimeError("Member %s has an invalid default value" % name)
            elif "table" in member:
                table_name = member["table"]
                table_values = self.tables[table_name]["values"]
                if default_value not in table_values:
                    raise RuntimeError("Member %s has an invalid default value" % name)
            elif re.match(r"^(?P<unsigned>u?)int(?P<bitsize>8|16|32|64)_t$", typ):
                m = re.match(r"^(?P<unsigned>u?)int(?P<bitsize>8|16|32|64)_t$", typ)
                unsigned = m.group("unsigned") != ""
                bitsize = int(m.group("bitsize"))
                if unsigned:
                    type_range = (0, 2 ** bitsize - 1)
                else:
                    type_range = (-2 ** (bitsize - 1) + 1, 2 ** (bitsize - 1) - 1)
                if isinstance(minimum, str) and re.match(r"^U?INT\d+_MIN$", minimum):
                    minimum = type_range[0]
                if isinstance(maximum, str) and re.match(r"^U?INT\d+_MAX$", maximum):
                    maximum = type_range[1]
                if not (isinstance(default_value, int) and not isinstance(default_value, bool)) and not isinstance(default_value, Symbol):
                    raise RuntimeError(
                        "Member %s default value has an invalid type, integer or symbol expected" % name
                    )
                if not isinstance(default_value, Symbol):
                    if not (type_range[0] <= default_value <= type_range[1]):
                        raise RuntimeError(
                            "Member %s default value is outside type's storage range, min %d, max %d"
                            % (name, type_range[0], type_range[1])
                        )
                if "max" not in member:
                    raise RuntimeError("Numeric member %s doesn't have maximum value defined" % name)
                if (
                    is_number_kind(default_value)
                    and is_number_kind(minimum)
                    and is_number_kind(maximum)
                    and not (minimum <= default_value <= maximum)
                ):
                    raise RuntimeError(
                        "Member %s default value is outside of the allowed range" % name
                    )
            elif typ == "float":
                if not is_number_kind(default_value) and not isinstance(default_value, Symbol):
                    raise RuntimeError(
                        "Member %s default value has an invalid type, numeric or symbol expected" % name
                    )
                if "max" not in member:
                    raise RuntimeError("Numeric member %s doesn't have maximum value defined" % name)
                if (
                    is_number_kind(default_value)
                    and is_number_kind(minimum)
                    and is_number_kind(maximum)
                    and not (minimum <= default_value <= maximum)
                ):
                    raise RuntimeError(
                        "Member %s default value is outside of the allowed range" % name
                    )
            elif typ == "string":
                maximum = ruby_to_i(member["max"])
                if not isinstance(default_value, str):
                    raise RuntimeError(
                        "Member %s default value has an invalid type, string expected" % name
                    )
                if len(default_value.encode("utf-8")) > maximum:
                    raise RuntimeError(
                        "Member %s default value is too long (max %d chars)"
                        % (name, maximum)
                    )
            else:
                raise RuntimeError("Unexpected type for member %s: %r" % (name, typ))

    # ---- output helpers ---------------------------------------------------

    @staticmethod
    def write_file_header(buf):
        buf.append("// This file has been automatically generated by utils/settings.rb\n")
        buf.append("// Don't make any modifications to it. They will be lost.\n\n")

    def ordered_table_names(self):
        return sorted(self.enabled_tables)

    @staticmethod
    def table_constant_name(name):
        return "TABLE_" + name.upper()

    @staticmethod
    def table_variable_name(name):
        return "table_" + name

    @staticmethod
    def var_type(typ):
        mapping = {
            "uint8_t": "VAR_UINT8",
            "bool": "VAR_UINT8",
            "int8_t": "VAR_INT8",
            "uint16_t": "VAR_UINT16",
            "int16_t": "VAR_INT16",
            "uint32_t": "VAR_UINT32",
            "float": "VAR_FLOAT",
            "string": "VAR_STRING",
        }
        if typ not in mapping:
            raise RuntimeError("unknown variable type %r" % typ)
        return mapping[typ]

    @staticmethod
    def value_type(group):
        return group.get("value_type") or "MASTER_VALUE"

    # ---- header generation ------------------------------------------------

    def write_header_file(self, filepath):
        buf = []
        self.write_file_header(buf)
        buf.append("#pragma once\n")
        buf.append("#define SETTING_MAX_NAME_LENGTH %d\n" % (self.max_name_length + 1))
        buf.append(
            "#define SETTING_MAX_WORD_LENGTH %d\n" % (self.name_encoder.max_word_length + 1)
        )
        buf.append(
            "#define SETTING_ENCODED_NAME_MAX_BYTES %d\n" % self.name_encoder.max_length
        )
        if self.name_encoder.uses_byte_indexing():
            buf.append("#define SETTING_ENCODED_NAME_USES_BYTE_INDEXING\n")
        buf.append(
            "#define SETTINGS_WORDS_BITS_PER_CHAR %d\n" % SETTINGS_WORDS_BITS_PER_CHAR
        )
        buf.append("#define SETTINGS_TABLE_COUNT %d\n" % self.count)

        offset_type = "uint16_t"
        if self.can_use_byte_offsetof():
            offset_type = "uint8_t"
        buf.append("typedef %s setting_offset_t;\n" % offset_type)

        pgn_count = 0
        for _group in self.iter_enabled_groups():
            pgn_count += 1
        buf.append("#define SETTINGS_PGN_COUNT %d\n" % pgn_count)

        buf.append("typedef %s setting_min_t;\n" % self.value_encoder.min_type())
        buf.append("typedef %s setting_max_t;\n" % self.value_encoder.max_type())
        buf.append(
            "#define SETTING_MIN_MAX_INDEX_BYTES %d\n" % (self.value_encoder.index_bytes() * 2)
        )

        table_names = self.ordered_table_names()
        buf.append("enum {\n")
        for name in table_names:
            buf.append("\t%s,\n" % self.table_constant_name(name))
        buf.append("\tLOOKUP_TABLE_COUNT,\n")
        buf.append("};\n")
        for name in table_names:
            buf.append("extern const char * const %s[];\n" % self.table_variable_name(name))

        for name, value in self.constants.items():
            buf.append(
                "#define SETTING_CONSTANT_%s %s\n" % (name.upper(), rb_inspect(value))
            )

        ii = 0
        for _group, member in self.iter_enabled_members():
            name = member["name"]
            typ = member["type"]
            default_value = member.get("default_value")

            if isinstance(default_value, Symbol) and default_value.name in ("zero", "target"):
                default_value = None
            elif "table" in member:
                table_name = member["table"]
                table_values = self.tables[table_name]["values"]
                if table_name == "off_on" and isinstance(default_value, bool):
                    default_value = "1" if default_value else "0"
                else:
                    try:
                        default_value = table_values.index(default_value)
                    except ValueError:
                        default_value = None
            elif typ == "string":
                data = list(default_value.encode("utf-8")) + [0]
                default_value = "{ " + ", ".join(str(b) for b in data) + " }"
            elif isinstance(default_value, float):
                default_value = ruby_float_to_s(default_value) + "f"

            minimum, maximum = self.resolve_range(member)
            setting_name = "SETTING_" + name.upper()
            if default_value is not None:
                buf.append("#define %s_DEFAULT %s\n" % (setting_name, default_value))
            buf.append("#define %s %d\n" % (setting_name, ii))
            buf.append("#define %s_MIN %s\n" % (setting_name, minimum))
            buf.append("#define %s_MAX %s\n" % (setting_name, maximum))
            ii += 1

        with open(filepath, "w") as f:
            f.write("".join(buf))

    # ---- implementation generation ---------------------------------------

    def write_impl_file(self, filepath):
        buf = []
        self.write_file_header(buf)

        def add_header(h):
            buf.append('#include "%s"\n' % h)

        add_header("platform.h")
        add_header("config/parameter_group_ids.h")
        add_header("fc/settings.h")

        for group in self.iter_enabled_groups():
            for h in group.get("headers") or []:
                add_header(h)

        buf.append('#pragma GCC diagnostic ignored "-Wunused-const-variable"\n')

        pgn_steps = []
        pgns = []
        for group in self.iter_enabled_groups():
            count = 0
            for member in group["members"]:
                if self.is_condition_enabled(member.get("condition")):
                    count += 1
            pgn_steps.append(count)
            pgns.append(group["name"])

        buf.append("const pgn_t settingsPgn[] = {\n")
        for p in pgns:
            buf.append("\t%s,\n" % p)
        buf.append("};\n")
        buf.append("const uint8_t settingsPgnCounts[] = {\n")
        for s in pgn_steps:
            buf.append("\t%s,\n" % s)
        buf.append("};\n")

        buf.append("static const uint8_t settingNamesWords[] = {\n")
        word_bits = SETTINGS_WORDS_BITS_PER_CHAR
        rem_symbols = [2 ** word_bits - 27]
        symbols = []
        state = {"acc": 0, "acc_bits": 0}

        def encode_byte(c):
            if c == 0:
                chr_ = 0
            elif ord("a") <= c <= ord("z"):
                chr_ = 1 + (c - ord("a"))
            elif ord("A") <= c <= ord("Z"):
                raise RuntimeError("Cannot encode uppercase character %d" % c)
            else:
                try:
                    idx = symbols.index(c)
                except ValueError:
                    if rem_symbols[0] == 0:
                        raise RuntimeError(
                            "Cannot encode character %d, no symbols remaining" % c
                        )
                    rem_symbols[0] -= 1
                    idx = len(symbols)
                    symbols.append(c)
                chr_ = 1 + (ord("z") - ord("a") + 1) + idx
            acc = state["acc"]
            acc_bits = state["acc_bits"]
            if acc_bits >= (8 - word_bits):
                remaining = 8 - acc_bits
                acc |= shl(chr_, remaining - word_bits)
                buf.append("0x%x," % acc)
                acc = shl(chr_, 8 - (word_bits - remaining)) & 0xFF
            else:
                acc |= shl(chr_, 3 - acc_bits)
            state["acc"] = acc
            state["acc_bits"] = (acc_bits + word_bits) % 8

        for word in self.name_encoder.words:
            buf.append("\t")
            for c in word.encode("ascii"):
                encode_byte(c)
            encode_byte(0)
            buf.append(" /* %s */ \n" % rb_str(word))

        if state["acc_bits"] > 0:
            buf.append("\t0x%x," % state["acc"])
            if state["acc_bits"] > (8 - word_bits):
                buf.append("0x00")
            buf.append("\n")
        buf.append("};\n")

        buf.append("static const char wordSymbols[] = {")
        for s in symbols:
            buf.append("'%s'," % chr(s))
        buf.append("};\n")

        table_names = self.ordered_table_names()
        for name in table_names:
            buf.append("const char * const %s[] = {\n" % self.table_variable_name(name))
            tbl = self.tables[name]
            if "values" not in tbl:
                raise RuntimeError("values not found for table %s" % name)
            for v in tbl["values"]:
                buf.append("\t%s,\n" % rb_inspect(v))
            buf.append("};\n")

        buf.append("static const lookupTableEntry_t settingLookupTables[] = {\n")
        for name in table_names:
            vn = self.table_variable_name(name)
            buf.append("\t{ %s, sizeof(%s) / sizeof(char*) },\n" % (vn, vn))
        buf.append("};\n")

        buf.append("static const uint32_t settingMinMaxTable[] = {\n")
        for v in self.value_encoder.values:
            buf.append("\t%s,\n" % v)
        buf.append("};\n")

        if self.value_encoder.index_bytes() == 1:
            buf.append("typedef uint8_t setting_min_max_idx_t;\n")
            buf.append("#define SETTING_INDEXES_GET_MIN(val) (val->config.minmax.indexes[0])\n")
            buf.append("#define SETTING_INDEXES_GET_MAX(val) (val->config.minmax.indexes[1])\n")
        else:
            raise RuntimeError(
                "can't encode indexed values requiring %d bytes"
                % self.value_encoder.index_bytes()
            )

        buf.append("static const setting_t settingsTable[] = {\n")

        last_group = None
        for group, member in self.iter_enabled_members():
            if group is not last_group:
                last_group = group
                buf.append("\t// %s\n" % group["name"])

            name = member["name"]
            buf.append("\t{ %s, " % self.name_encoder.format_encoded_name(name))
            buf.append("%s | %s" % (self.var_type(member["type"]), self.value_type(group)))
            tbl = member.get("table")
            if tbl:
                buf.append(" | MODE_LOOKUP")
                buf.append(", .config.lookup = { %s }" % self.table_constant_name(tbl))
            else:
                minimum, maximum = self.resolve_range(member)
                if minimum > maximum:
                    raise RuntimeError(
                        "Error encoding %s: min (%s) > max (%s)" % (name, minimum, maximum)
                    )
                enc = self.value_encoder.encode_values(minimum, maximum)
                buf.append(", .config.minmax.indexes = %s" % enc)
            buf.append(
                ", (setting_offset_t)offsetof(%s, %s) },\n" % (group["type"], member["field"])
            )
        buf.append("};\n")

        with open(filepath, "w") as f:
            f.write("".join(buf))


def usage():
    print(
        "Usage: python3 %s <source_dir> <settings_file> [--use_host_gcc] "
        "[--json <json_file>] [-o <output_dir>]" % sys.argv[0]
    )


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("src_root")
    parser.add_argument("settings_file")
    parser.add_argument("-o", "--output-dir", dest="output_dir", default=None)
    parser.add_argument("-j", "--json", dest="json_file", default=None)
    parser.add_argument("-g", "--use_host_gcc", dest="use_host_gcc", action="store_true")
    parser.add_argument("-h", "--help", dest="help", action="store_true")

    opts, extra = parser.parse_known_args(argv)
    if opts.help:
        usage()
        return 0
    if extra:
        usage()
        return 1

    gen = Generator(opts.src_root, opts.settings_file, opts.output_dir, opts.use_host_gcc)

    if opts.json_file:
        gen.write_json(opts.json_file)
    else:
        gen.write_files()
        if os.environ.get("V") == "1":
            gen.print_stats()
    return 0


if __name__ == "__main__":
    sys.exit(main())
