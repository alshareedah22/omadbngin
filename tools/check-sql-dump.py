#!/usr/bin/env python3
"""Refuse a plain-SQL dump that could make psql run client-side meta-commands.

psql executes "\\!" and friends wherever its lexer finds a backslash outside quotes, comments
and COPY data. This follows psql's own lexing (quotes, dollar quotes, comments, COPY ... FROM
stdin data) and accepts a backslash only in the forms pg_dumpall writes: \\connect, \\restrict and
\\unrestrict at the start of a statement, and the \\. that ends COPY data. Anything it cannot
decide is refused. Usage: check-sql-dump.py <file>; exit 0 = safe to feed to psql.
"""
import re
import sys


def refuse(n, why):
    sys.stderr.write("line %d: %s\n" % (n, why))
    sys.exit(1)


IDENT = re.compile(r"[A-Za-z0-9_\x80-\U0010ffff$]")
WORD = re.compile(r"[A-Za-z0-9_\x80-\U0010ffff$]+")
TAG = re.compile(r"\$([A-Za-z_\x80-\U0010ffff][A-Za-z0-9_\x80-\U0010ffff]*)?\$")
META_OK = [
    re.compile(r"^\\(connect|c)[ \t]+[^\\`\r\n]*$"),
    re.compile(r"^\\(restrict|unrestrict)[ \t]+[A-Za-z0-9]+$"),
]

with open(sys.argv[1], encoding="utf-8", errors="surrogateescape", newline="") as f:
    text = f.read()

# A client encoding such as SJIS has backslash as a trailing byte; pg_dumpall only ever sets UTF8.
if re.search(r"(?i)client_encoding", text):
    allowed = len(re.findall(r"(?m)^SET client_encoding = 'UTF8';\r?$", text))
    if len(re.findall(r"(?i)client_encoding", text)) != allowed:
        refuse(1, "the dump changes client_encoding")

state = "normal"  # normal | squote | estr | dquote | dollar | block
tag = ""
block_depth = 0
paren = 0
atstart = True  # no token of a statement seen yet
prev_word = ""
words = []  # words of the current statement, outside quotes
in_copy = False
copy_pending = False  # the statement began with COPY

for ln, raw in enumerate(text.split("\n"), 1):
    line = raw[:-1] if raw.endswith("\r") else raw
    if in_copy:
        if line.startswith("\\."):
            if line != "\\.":
                refuse(ln, "text after the end-of-data marker")
            in_copy = False
            atstart, words, prev_word = True, [], ""
        continue
    i, n = 0, len(line)
    code = False  # a token came before position i on this line
    while i < n:
        c = line[i]
        if state == "normal":
            if c in " \t\f\v":
                i += 1
            elif line.startswith("--", i):
                i = n
            elif line.startswith("/*", i):
                state, block_depth, i = "block", 1, i + 2
            elif c == "'":
                prev = line[i - 1] if i else " "
                before = line[i - 2] if i > 1 else " "
                state = "estr" if prev in "eE" and not IDENT.match(before) else "squote"
                i += 1
                atstart, code = False, True
            elif c == '"':
                state, i = "dquote", i + 1
                atstart, code = False, True
            elif c == "$":
                m = TAG.match(line, i)
                if m and not (i and IDENT.match(line[i - 1])):
                    state, tag, i = "dollar", m.group(0), i + len(m.group(0))
                else:
                    i += 1
                atstart, code = False, True
            elif c == "\\":
                if not (atstart and not code and paren == 0):
                    refuse(ln, "a backslash command in the middle of a statement")
                if not any(p.match(line[i:]) for p in META_OK):
                    refuse(ln, "client-side command %r is not allowed" % line[i:i + 20])
                i = n
            elif c == ";":
                i += 1
                code = True
                if paren == 0:
                    if copy_pending:
                        if line[i:].strip() or words[-2:] != ["from", "stdin"] or "program" in words:
                            refuse(ln, "only a plain COPY ... FROM stdin; is allowed")
                        in_copy = True
                    atstart, words, copy_pending, prev_word = True, [], False, ""
            elif c == "(":
                paren += 1
                i += 1
                atstart, code = False, True
            elif c == ")":
                paren = max(0, paren - 1)
                i += 1
                code = True
            elif IDENT.match(c):
                m = WORD.match(line, i)
                w = m.group(0).lower()
                if atstart and not words and w == "copy":
                    copy_pending = True
                if prev_word == "begin" and w == "atomic":
                    refuse(ln, "SQL-standard function bodies (BEGIN ATOMIC) cannot be checked")
                words.append(w)
                prev_word = w
                atstart, code = False, True
                i = m.end()
            else:
                i += 1
                atstart, code = False, True
        elif state == "squote":
            j = line.find("'", i)
            if j < 0:
                i = n
            else:
                k = j - 1
                while k >= i and line[k] == "\\":
                    k -= 1
                if (j - 1 - k) % 2:
                    refuse(ln, "a quote after a backslash: its meaning depends on a server setting")
                if line.startswith("''", j):
                    i = j + 2
                else:
                    state, i = "normal", j + 1
        elif state == "estr":
            j = i
            while j < n and line[j] != "'":
                j += 2 if line[j] == "\\" else 1
            if j >= n:
                i = n
            elif line.startswith("''", j):
                i = j + 2
            else:
                state, i = "normal", j + 1
        elif state == "dquote":
            j = line.find('"', i)
            if j < 0:
                i = n
            elif line.startswith('""', j):
                i = j + 2
            else:
                state, i = "normal", j + 1
        elif state == "dollar":
            j = line.find(tag, i)
            if j < 0:
                i = n
            else:
                state, i = "normal", j + len(tag)
        else:  # block comment
            if line.startswith("*/", i):
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    state = "normal"
            elif line.startswith("/*", i):
                block_depth += 1
                i += 2
            else:
                i += 1
    if copy_pending and not in_copy:
        refuse(ln, "a COPY statement must fit on one line")

sys.exit(0)
