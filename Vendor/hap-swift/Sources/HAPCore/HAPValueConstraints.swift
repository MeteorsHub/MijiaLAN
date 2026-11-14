// Added for MijiaLAN; see Vendor/hap-swift/README.md.
import Foundation

/// HAP strings count UTF-8 bytes, not Swift characters. Truncation never splits a Unicode scalar.
public enum HAPString {
    public static let defaultMaxBytes = 64

    public static func bounded(_ text: String, maxBytes: Int = defaultMaxBytes) -> String {
        let limit = max(0, maxBytes)
        guard text.utf8.count > limit else { return text }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            guard bytes + count <= limit else { break }
            result.append(scalar)
            bytes += count
        }
        return String(result)
    }
}

extension HAPCharacteristic {
    /// The same wire constraints apply to initial values, polling, GETs, and events. A read is rounded
    /// to its advertised step and type; an invalid type, nonfinite or out-of-range source is unavailable.
    public func normalizedRead(_ value: HAPCharacteristicValue) -> HAPCharacteristicValue? {
        normalize(value, writing: false)
    }

    /// Writes must already satisfy the declared step and integral format, before device conversion.
    public func normalizedWrite(_ value: HAPCharacteristicValue) -> HAPCharacteristicValue? {
        normalize(value, writing: true)
    }

    private func normalize(_ value: HAPCharacteristicValue, writing: Bool) -> HAPCharacteristicValue? {
        if format == .string {
            guard case .string(let text) = value else { return nil }
            guard text.utf8.count <= HAPString.defaultMaxBytes else { return nil }
            return .string(text)
        }
        let number: Double? = switch value {
        case .uint8(let n): Double(n)
        case .uint16(let n): Double(n)
        case .uint32(let n): Double(n)
        case .int32(let n): Double(n)
        case .float(let n): n
        default: nil
        }
        if format == .bool {
            if case .bool = value { return value }
            guard let number, number == 0 || number == 1 else { return nil }
            return .bool(number == 1)
        }
        let bounds: (Double, Double, Bool)
        switch format {
        case .float: bounds = (-Double(Float.greatestFiniteMagnitude), Double(Float.greatestFiniteMagnitude), false)
        case .int: bounds = (Double(Int32.min), Double(Int32.max), true)
        case .uint8: bounds = (0, Double(UInt8.max), true)
        case .uint16: bounds = (0, Double(UInt16.max), true)
        case .uint32: bounds = (0, Double(UInt32.max), true)
        case .data: if case .data = value { return value }; return nil
        case .tlv8: if case .tlv8 = value { return value }; return nil
        default: return nil
        }
        let lower = max(minValue ?? bounds.0, bounds.0)
        let upper = min(maxValue ?? bounds.1, bounds.1)
        let step = minStep ?? (bounds.2 ? 1 : 0)
        guard lower.isFinite, upper.isFinite, lower <= upper, step.isFinite, step >= 0,
              var number, number.isFinite, number >= lower, number <= upper else { return nil }
        if let validValues, !validValues.contains(where: { Double($0) == number }) { return nil }
        let base = minValue ?? 0
        if writing {
            if bounds.2 && abs(number - number.rounded(.towardZero)) > 1e-6 { return nil }
            if step > 0 {
                let units = (number - base) / step
                guard units.isFinite, abs(units - units.rounded()) <= 1e-6 else { return nil }
            }
        } else if step > 0 {
            number = base + ((number - base) / step).rounded() * step
            if number > upper { number = base + ((upper - base) / step).rounded(.down) * step }
            number = max(number, lower)
        }
        guard number.isFinite else { return nil }
        if bounds.2 {
            number = number.rounded()
            guard number >= bounds.0, number <= bounds.1 else { return nil }
        }
        switch format {
        case .uint8: return .uint8(UInt8(number))
        case .uint16: return .uint16(UInt16(number))
        case .uint32: return .uint32(UInt32(number))
        case .int: return .int32(Int32(number))
        default: return .float(number)
        }
    }
}
