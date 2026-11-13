import Foundation

/// Recursive-descent arithmetic. Never throws or traps on bad input; returns nil.
public enum Calculator {
    public struct Result: Equatable, Sendable {
        public let value: Double
        public let formatted: String
    }

    /// Evaluates `input` if it is a real calculation: it must parse completely
    /// and contain at least one operator or function call, so that "42" or
    /// "pi" alone do not count as math.
    public static func evaluate(_ input: String) -> Result? {
        var text = input.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("=") { text.removeLast() }
        if text.hasPrefix("=") { text.removeFirst() }
        guard !text.isEmpty, text.unicodeScalars.count <= 256 else { return nil }
        var parser = Parser(Array(text.unicodeScalars))
        guard let value = parser.parseExpression(), parser.atEnd, parser.operations > 0 else { return nil }
        guard value.isFinite else { return nil }
        return Result(value: value, formatted: format(value))
    }

    public static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var s = String(format: "%.10g", value)
        if s.contains("e") { return s }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var operations = 0
        var depth = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { mutating get { skipSpaces(); return i >= s.count } }

        mutating func skipSpaces() {
            while i < s.count, s[i].properties.isWhitespace { i += 1 }
        }

        mutating func peek() -> Unicode.Scalar? {
            skipSpaces()
            return i < s.count ? s[i] : nil
        }

        mutating func eat(_ c: Unicode.Scalar) -> Bool {
            if peek() == c { i += 1; return true }
            return false
        }

        mutating func parseExpression() -> Double? {
            depth += 1
            defer { depth -= 1 }
            if depth > 64 { return nil }
            guard var value = parseTerm() else { return nil }
            while let c = peek() {
                if c == "+" {
                    i += 1
                    guard let rhs = parseTerm() else { return nil }
                    value += rhs
                } else if c == "-" || c == "−" {
                    i += 1
                    guard let rhs = parseTerm() else { return nil }
                    value -= rhs
                } else {
                    break
                }
                operations += 1
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let c = peek() {
                if c == "*" || c == "×" || c == "·" {
                    i += 1
                    guard let rhs = parseUnary() else { return nil }
                    value *= rhs
                } else if c == "/" || c == "÷" {
                    i += 1
                    guard let rhs = parseUnary() else { return nil }
                    value /= rhs
                } else if c == "%" {
                    i += 1
                    guard let rhs = parseUnary() else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                } else if c == "(" || isIdentifierStart(c) {
                    // Implicit multiplication: 2(3+4), 2pi
                    guard let rhs = parsePower() else { return nil }
                    value *= rhs
                } else {
                    break
                }
                operations += 1
            }
            return value
        }

        mutating func parseUnary() -> Double? {
            if eat("-") || eat("−") {
                depth += 1
                defer { depth -= 1 }
                if depth > 64 { return nil }
                return parseUnary().map { -$0 }
            }
            if eat("+") { return parseUnary() }
            return parsePower()
        }

        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if eat("^") {
                operations += 1
                guard let exponent = parseUnary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            while true {
                if eat("!") {
                    guard value >= 0, value <= 170, value == value.rounded() else { return nil }
                    value = (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
                    operations += 1
                } else if peek() == "%", isPercentPosition() {
                    i += 1
                    value /= 100
                    operations += 1
                } else {
                    return value
                }
            }
        }

        /// "%" is a percent sign when nothing that could be an operand follows it.
        func isPercentPosition() -> Bool {
            var j = i + 1
            while j < s.count, s[j].properties.isWhitespace { j += 1 }
            guard j < s.count else { return true }
            return "+-−*×/÷)^,".unicodeScalars.contains(s[j])
        }

        func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic
        }

        mutating func parsePrimary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                guard let v = parseExpression(), eat(")") else { return nil }
                return v
            }
            if ("0"..."9").contains(c) || c == "." { return parseNumber() }
            if isIdentifierStart(c) { return parseIdentifier() }
            return nil
        }

        mutating func parseNumber() -> Double? {
            let start = i
            if i + 1 < s.count, s[i] == "0", s[i + 1] == "x" || s[i + 1] == "X" {
                i += 2
                let digitsStart = i
                while i < s.count, s[i].properties.isASCIIHexDigit { i += 1 }
                guard i > digitsStart else { return nil }
                return UInt64(String(String.UnicodeScalarView(s[digitsStart..<i])), radix: 16).map { Double($0) }
            }
            while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
            if i < s.count, s[i] == "." {
                i += 1
                while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
            }
            // Exponent only when followed by digits, so "2e" stays "2 * e".
            if i < s.count, s[i] == "e" || s[i] == "E" {
                var j = i + 1
                if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
                if j < s.count, ("0"..."9").contains(s[j]) {
                    while j < s.count, ("0"..."9").contains(s[j]) { j += 1 }
                    i = j
                }
            }
            return Double(String(String.UnicodeScalarView(s[start..<i])))
        }

        mutating func parseIdentifier() -> Double? {
            let start = i
            while i < s.count, s[i].properties.isAlphabetic || ("0"..."9").contains(s[i]) { i += 1 }
            let name = String(String.UnicodeScalarView(s[start..<i])).lowercased()

            switch name {
            case "pi", "π": return Double.pi
            case "tau", "τ": return 2 * Double.pi
            case "e": return M_E
            default: break
            }

            guard eat("(") else { return nil }
            var args = [Double]()
            repeat {
                guard let v = parseExpression() else { return nil }
                args.append(v)
            } while eat(",")
            guard eat(")") else { return nil }
            operations += 1

            if args.count == 1 {
                let x = args[0]
                switch name {
                case "sqrt": return x.squareRoot()
                case "cbrt": return cbrt(x)
                case "abs": return abs(x)
                case "sin": return sin(x)
                case "cos": return cos(x)
                case "tan": return tan(x)
                case "asin": return asin(x)
                case "acos": return acos(x)
                case "atan": return atan(x)
                case "ln": return log(x)
                case "log", "log10": return log10(x)
                case "log2": return log2(x)
                case "exp": return exp(x)
                case "floor": return floor(x)
                case "ceil": return ceil(x)
                case "round": return x.rounded()
                default: break
                }
            }
            switch name {
            case "min": return args.min()
            case "max": return args.max()
            case "pow" where args.count == 2: return pow(args[0], args[1])
            case "atan2" where args.count == 2: return atan2(args[0], args[1])
            default: return nil
            }
        }
    }
}
