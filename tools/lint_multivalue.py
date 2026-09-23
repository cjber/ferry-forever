"""Reject accidental select() expansion in Lua 5.1 expression lists.

Parentheses force one result. Intentional expansion needs a trailing
``-- multi-value: reason`` on the call, constructor, or return's final line.
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path

LONG = re.compile(r"\[(=*)\[")
WORD = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
NUMBER = re.compile(r"(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")
KEYWORDS = set(
    "and break do else elseif end false for function if in local nil not or repeat return then true until while".split()
)
PRECEDENCE = {
    "or": 1,
    "and": 2,
    "<": 3,
    ">": 3,
    "<=": 3,
    ">=": 3,
    "~=": 3,
    "==": 3,
    "..": 4,
    "+": 5,
    "-": 5,
    "*": 6,
    "/": 6,
    "%": 6,
    "^": 8,
}


@dataclass(frozen=True)
class Token:
    value: str
    kind: str
    line: int


def tokenize(source):
    tokens, allowances = [], set()
    pos, line = 0, 1
    while pos < len(source):
        start, start_line = pos, line
        char = source[pos]
        comment = source.startswith("--", pos)
        long = LONG.match(source, pos + 2 if comment else pos)
        if long:
            close = "]" + long[1] + "]"
            end = source.find(close, long.end())
            if end < 0:
                raise ValueError(f"{line}: unterminated long string/comment")
            pos = end + len(close)
            if not comment:
                tokens.append(Token(source[start:pos], "string", line))
        elif comment:
            end = source.find("\n", pos)
            pos = len(source) if end < 0 else end
            if re.fullmatch(r"--\s*multi-value:\s*\S.*", source[start:pos].rstrip()):
                allowances.add(line)
        elif char.isspace():
            pos += 1
        elif char in "\"'":
            pos += 1
            while pos < len(source) and source[pos] != char:
                if source[pos] == "\\":
                    pos += 1
                elif source[pos] in "\r\n":
                    raise ValueError(f"{line}: newline in short string")
                pos += 1
            if pos >= len(source):
                raise ValueError(f"{line}: unterminated string")
            pos += 1
            tokens.append(Token(source[start:pos], "string", line))
        elif word := WORD.match(source, pos):
            pos = word.end()
            tokens.append(Token(word[0], "keyword" if word[0] in KEYWORDS else "name", line))
        elif number := NUMBER.match(source, pos):
            pos = number.end()
            tokens.append(Token(number[0], "number", line))
        else:
            symbol = next((s for s in ("...", "..", "==", "~=", "<=", ">=") if source.startswith(s, pos)), char)
            if char not in "+-*/%^#=<>~;:,().{}[]":
                raise ValueError(f"{line}: unexpected character {char!r}")
            pos += len(symbol)
            tokens.append(Token(symbol, "symbol", line))
        line = start_line + source[start:pos].count("\n")
    tokens.append(Token("<eof>", "eof", line))
    return tokens, allowances


class Parser:
    def __init__(self, source):
        self.tokens, self.allowances = tokenize(source)
        self.index = 0
        self.hits = []

    @property
    def token(self):
        return self.tokens[self.index]

    def take(self, value=None):
        token = self.token
        if value is not None and token.value != value:
            raise ValueError(f"{token.line}: expected {value!r}, got {token.value!r}")
        self.index += 1
        return token

    def accept(self, value):
        if self.token.value == value:
            return self.take()
        return None

    def name(self):
        if self.token.kind != "name":
            raise ValueError(f"{self.token.line}: expected a name, got {self.token.value!r}")
        return self.take()

    def check(self, select, context, end_line):
        if select and end_line not in self.allowances:
            self.hits.append((select.line, context))

    def expressions(self):
        last = self.expression()
        while self.accept(","):
            last = self.expression()
        return last

    def expression(self, minimum=0):
        if self.token.value in {"not", "-", "#"}:
            self.take()
            self.expression(7)
            select = None
        else:
            select = self.atom()
        while PRECEDENCE.get(self.token.value, -1) >= minimum:
            operator = self.take().value
            self.expression(PRECEDENCE[operator] + (operator not in {"^", ".."}))
            select = None
        return select

    def atom(self):
        token = self.token
        select, bare = None, None
        if self.accept("function"):
            self.function_body()
            return None
        if token.value == "{":
            self.table()
            return None
        if token.kind in {"number", "string"} or token.value in {"nil", "true", "false", "..."}:
            self.take()
            return None
        if self.accept("("):
            self.expression()
            self.take(")")
        else:
            bare = self.name()
        while True:
            if self.accept("."):
                self.name()
            elif self.accept("["):
                self.expression()
                self.take("]")
            elif self.accept(":"):
                self.name()
                self.arguments()
            elif self.token.value in {"(", "{"} or self.token.kind == "string":
                self.arguments()
                select = bare if bare and bare.value == "select" else None
                bare = None
                continue
            else:
                return select
            bare, select = None, None

    def arguments(self):
        if self.accept("("):
            last = None if self.token.value == ")" else self.expressions()
            end = self.take(")")
            self.check(last, "last call argument", end.line)
        elif self.token.value == "{":
            self.table()
        elif self.token.kind == "string":
            self.take()
        else:
            raise ValueError(f"{self.token.line}: expected call arguments")

    def table(self):
        self.take("{")
        last = None
        while self.token.value != "}":
            if self.accept("["):
                self.expression()
                self.take("]")
                self.take("=")
                self.expression()
                last = None
            elif self.token.kind == "name" and self.tokens[self.index + 1].value == "=":
                self.name()
                self.take("=")
                self.expression()
                last = None
            else:
                last = self.expression()
            if not (self.accept(",") or self.accept(";")):
                break
        end = self.take("}")
        self.check(last, "last table element", end.line)

    def function_body(self):
        self.take("(")
        if self.token.value != ")":
            while True:
                if self.accept("..."):
                    break
                self.name()
                if not self.accept(","):
                    break
        self.take(")")
        self.block()
        self.take("end")

    def block(self):
        while self.token.value not in {"end", "else", "elseif", "until", "<eof>"}:
            self.statement()

    def statement(self):
        if self.accept(";") or self.accept("break"):
            return
        if self.accept("return"):
            if self.token.value not in {"end", "else", "elseif", "until", "<eof>", ";"}:
                last = self.expressions()
                self.accept(";")
                self.check(last, "last return value", self.tokens[self.index - 1].line)
        elif self.accept("if"):
            self.expression()
            self.take("then")
            self.block()
            while self.accept("elseif"):
                self.expression()
                self.take("then")
                self.block()
            if self.accept("else"):
                self.block()
            self.take("end")
        elif self.accept("repeat"):
            self.block()
            self.take("until")
            self.expression()
        elif self.token.value in {"while", "for", "do"}:
            kind = self.take().value
            if kind == "while":
                self.expression()
            elif kind == "for":
                self.name()
                if self.accept("="):
                    self.expressions()
                else:
                    while self.accept(","):
                        self.name()
                    self.take("in")
                    self.expressions()
            if kind != "do":
                self.take("do")
            self.block()
            self.take("end")
        elif self.accept("function"):
            self.name()
            while self.accept("."):
                self.name()
            if self.accept(":"):
                self.name()
            self.function_body()
        elif self.accept("local"):
            if self.accept("function"):
                self.name()
                self.function_body()
            else:
                self.name()
                while self.accept(","):
                    self.name()
                if self.accept("="):
                    self.expressions()
        else:
            self.atom()
            while self.accept(","):
                self.atom()
            if self.accept("="):
                self.expressions()


def lint(source):
    parser = Parser(source)
    parser.block()
    parser.take("<eof>")
    return parser.hits


def main():
    paths = [Path(arg) for arg in sys.argv[1:]] if len(sys.argv) > 1 else sorted(Path.cwd().rglob("*.lua"))
    failed = False
    for path in paths:
        if any(part.startswith(".") or part == "__pycache__" for part in path.resolve().relative_to(Path.cwd()).parts):
            continue
        try:
            for line, context in lint(path.read_text()):
                print(f"{path}:{line}: multi-value: select() as {context}; use parentheses or a reason comment")
                failed = True
        except ValueError as error:
            print(f"{path}:{error}")
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
