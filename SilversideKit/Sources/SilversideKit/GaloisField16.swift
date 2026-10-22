/// Arithmetic in GF(2^16) with the polynomial x^16 + x^12 + x^3 + x + 1 (0x1100B)
/// and the generator α = 2, the field that CUETools DB uses for its repair data.
public enum GaloisField16 {
    /// The number of nonzero elements, and the period of α.
    public static let order = 65535

    /// α^e for e in 0..<2 × order, so a sum of two logarithms needs no reduction.
    static let exp: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 2 * order)
        var value = 1
        for e in 0..<order {
            table[e] = UInt16(value)
            table[e + order] = UInt16(value)
            value <<= 1
            if value & 0x10000 != 0 { value ^= 0x1100B }
        }
        return table
    }()

    /// The logarithm to base α of each nonzero element. `log[0]` is not used.
    static let log: [Int] = {
        var table = [Int](repeating: 0, count: order + 1)
        for e in 0..<order { table[Int(exp[e])] = e }
        return table
    }()

    @inline(__always)
    public static func multiply(_ a: UInt16, _ b: UInt16) -> UInt16 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }

    /// a × α^e, for e in 0..<order.
    @inline(__always)
    public static func multiply(_ a: UInt16, byAlphaPower e: Int) -> UInt16 {
        a == 0 ? 0 : exp[log[Int(a)] + e]
    }

    public static func divide(_ a: UInt16, _ b: UInt16) -> UInt16 {
        precondition(b != 0, "Division by zero")
        return a == 0 ? 0 : exp[log[Int(a)] + order - log[Int(b)]]
    }

    /// α^e for any integer e.
    public static func alphaPower(_ e: Int) -> UInt16 {
        exp[((e % order) + order) % order]
    }
}

/// A Reed–Solomon decoder for one codeword whose syndromes are S_i = C(α^i),
/// i = 0 ..< count, as CUETools DB defines them: each wrong symbol at degree p
/// with error e adds e × α^(i × p) to S_i.
public enum ReedSolomonDecoder {
    public struct Correction: Equatable, Sendable {
        /// The degree of the wrong symbol in the codeword polynomial.
        public var degree: Int
        /// The value to XOR into the symbol to correct it.
        public var error: UInt16
    }

    /// Finds the wrong symbols from the syndromes, among degrees 0 ..< `length`.
    ///
    /// `erasures` are degrees known to be suspect. With e erasures and v other errors,
    /// the decoder corrects them if e + 2v ≤ `syndromes.count`, so known suspects cost
    /// half as much. An erasure whose symbol is right gets no correction. Returns nil
    /// if the errors cannot be corrected, or if there are more than `maximumErrors`
    /// wrong symbols: that check comes before the costly search for their places.
    public static func corrections(
        syndromes: [UInt16], length: Int, erasures: [Int] = [], maximumErrors: Int = .max
    ) -> [Correction]? {
        typealias GF = GaloisField16
        guard syndromes.contains(where: { $0 != 0 }) else { return [] }
        guard erasures.count <= syndromes.count else { return nil }

        // The erasure locator Γ(x) = Π (1 + α^p x) over the erasures.
        var erasureLocator: [UInt16] = [1]
        for p in erasures {
            let location = GF.alphaPower(p)
            var product = erasureLocator + [0]
            for i in erasureLocator.indices { product[i + 1] ^= GF.multiply(erasureLocator[i], location) }
            erasureLocator = product
        }

        // Berlekamp–Massey, started from Γ: the locator Λ(x) of all wrong symbols, with
        // Λ(X⁻¹) = 0 for each location X = α^p.
        let e = erasures.count
        var locator = erasureLocator
        var previous = erasureLocator
        var size = e
        var shift = 1
        var lastDiscrepancy: UInt16 = 1
        for n in e..<syndromes.count {
            var discrepancy: UInt16 = 0
            for i in 0..<min(locator.count, n + 1) {
                discrepancy ^= GF.multiply(locator[i], syndromes[n - i])
            }
            if discrepancy == 0 {
                shift += 1
                continue
            }
            let scale = GF.divide(discrepancy, lastDiscrepancy)
            var updated = locator
            if updated.count < previous.count + shift {
                updated += [UInt16](repeating: 0, count: previous.count + shift - updated.count)
            }
            for i in previous.indices { updated[i + shift] ^= GF.multiply(scale, previous[i]) }
            if 2 * size <= n + e {
                previous = locator
                size = n + 1 + e - size
                lastDiscrepancy = discrepancy
                shift = 1
            } else {
                shift += 1
            }
            locator = updated
        }
        while locator.count > 1 && locator.last == 0 { locator.removeLast() }
        let degree = locator.count - 1
        guard degree == size, degree > 0, 2 * degree - e <= syndromes.count, degree <= maximumErrors else { return nil }

        // Chien search: test each degree p, by Λ(α^-p) = 0. Term i is Λ_i α^(-p i), kept
        // as its logarithm, so going from p to p + 1 subtracts i.
        var locations = [Int]()
        GF.exp.withUnsafeBufferPointer { exp in
            var logs = locator.map { $0 == 0 ? -1 : GF.log[Int($0)] }
            let steps = (0..<logs.count).map { (GF.order - $0 % GF.order) % GF.order }
            for p in 0..<length {
                var value: UInt16 = 0
                for i in logs.indices where logs[i] >= 0 { value ^= exp[logs[i]] }
                if value == 0 {
                    locations.append(p)
                    if locations.count == degree { break }
                }
                for i in 1..<logs.count where logs[i] >= 0 {
                    logs[i] += steps[i]
                    if logs[i] >= GF.order { logs[i] -= GF.order }
                }
            }
        }
        guard locations.count == degree else { return nil }

        // Forney: Ω(x) = S(x)Λ(x) mod x^count, and the error at X is X × Ω(X⁻¹) / Λ'(X⁻¹).
        var evaluator = [UInt16](repeating: 0, count: syndromes.count)
        for (i, coefficient) in locator.enumerated() where i < syndromes.count {
            for j in 0..<(syndromes.count - i) { evaluator[i + j] ^= GF.multiply(coefficient, syndromes[j]) }
        }
        var corrections = [Correction]()
        for p in locations {
            let inverse = GF.alphaPower(-p)
            var omega: UInt16 = 0
            var power: UInt16 = 1
            for coefficient in evaluator {
                omega ^= GF.multiply(coefficient, power)
                power = GF.multiply(power, inverse)
            }
            // In characteristic 2, Λ'(x) keeps only the odd terms: Λ_1 + Λ_3 x² + ...
            var derivative: UInt16 = 0
            power = 1
            let inverseSquared = GF.multiply(inverse, inverse)
            for i in stride(from: 1, to: locator.count, by: 2) {
                derivative ^= GF.multiply(locator[i], power)
                power = GF.multiply(power, inverseSquared)
            }
            // A zero derivative means a repeated root, so the locator is not valid.
            guard derivative != 0 else { return nil }
            let error = GF.multiply(GF.alphaPower(p), GF.divide(omega, derivative))
            if error != 0 { corrections.append(Correction(degree: p, error: error)) }
        }
        return corrections
    }
}
