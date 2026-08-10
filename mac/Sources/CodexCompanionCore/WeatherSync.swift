import Foundation

public struct WeatherConfiguration: Codable, Equatable, Sendable {
    public var city: String
    public var enabled: Bool
    public var usesCelsius: Bool
    public var refreshMinutes: UInt8

    public init(
        city: String = "",
        enabled: Bool = true,
        usesCelsius: Bool = true,
        refreshMinutes: UInt8 = 30
    ) {
        self.city = city
        self.enabled = enabled
        self.usesCelsius = usesCelsius
        self.refreshMinutes = [15, 30, 60].contains(refreshMinutes) ? refreshMinutes : 30
    }

    public var normalized: WeatherConfiguration {
        WeatherConfiguration(
            city: city.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            usesCelsius: usesCelsius,
            refreshMinutes: refreshMinutes
        )
    }
}

public final class WeatherConfigurationStore: @unchecked Sendable {
    public static let configurationDidChange = Notification.Name(
        "com.openlai.codex-companion.weather-configuration-changed"
    )
    public static let defaultURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexCompanion", isDirectory: true)
            .appendingPathComponent("weather.json")
    }()

    private let url: URL

    public init(url: URL = defaultURL) { self.url = url }

    public func load() -> WeatherConfiguration {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WeatherConfiguration.self, from: data)
        else { return WeatherConfiguration() }
        return value.normalized
    }

    public func save(_ configuration: WeatherConfiguration) throws {
        let normalized = configuration.normalized
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(normalized).write(to: url, options: [.atomic])
#if os(macOS)
        DistributedNotificationCenter.default().post(
            name: Self.configurationDidChange, object: nil
        )
#endif
    }
}

public struct WeatherSnapshot: Equatable, Sendable {
    public let city: String
    public let temperatureTenthsCelsius: Int16
    public let weatherCode: UInt8
    public let fetchedAt: Date

    public init(
        city: String,
        temperatureTenthsCelsius: Int16,
        weatherCode: UInt8,
        fetchedAt: Date = Date()
    ) {
        self.city = city
        self.temperatureTenthsCelsius = temperatureTenthsCelsius
        self.weatherCode = weatherCode
        self.fetchedAt = fetchedAt
    }

    public var devicePayload: DeviceWeatherPayload {
        return DeviceWeatherPayload(
            city: deviceSafeCity,
            temperatureTenthsCelsius: temperatureTenthsCelsius,
            weatherCode: weatherCode
        )
    }

    /// The embedded font contains the product's fixed Chinese strings, but it
    /// cannot reasonably embed every city name in CJK. Keep dynamic city text
    /// inside the font's guaranteed ASCII range so a new location can never
    /// introduce LVGL missing-glyph squares.
    private var deviceSafeCity: String {
        let latin = city.applyingTransform(.toLatin, reverse: false) ?? city
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let filteredScalars = plain.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let allowed = (0x30...0x39).contains(value) ||
                (0x41...0x5A).contains(value) ||
                (0x61...0x7A).contains(value) ||
                scalar == " " || scalar == "-" || scalar == "'" || scalar == "."
            return allowed ? Character(String(scalar)) : " "
        }
        let normalized = String(filteredScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String((normalized.isEmpty ? "Local" : normalized).prefix(48))
            .trimmingCharacters(in: .whitespaces)
    }
}

public enum WeatherSyncError: LocalizedError, Equatable {
    case emptyCity
    case cityNotFound
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyCity: "请先填写城市"
        case .cityNotFound: "未找到该城市"
        case .invalidResponse: "天气服务返回了无效数据"
        case .httpStatus(let status): "天气服务请求失败（HTTP \(status)）"
        }
    }
}

public struct OpenMeteoWeatherClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func fetch(city rawCity: String) async throws -> WeatherSnapshot {
        let city = rawCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2 else { throw WeatherSyncError.emptyCity }
        var geocoding = URLComponents(
            string: "https://geocoding-api.open-meteo.com/v1/search"
        )!
        geocoding.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            // Keep localized lookup so Chinese city input remains searchable.
            // WeatherSnapshot.devicePayload transliterates only the compact
            // device-facing label into the embedded font's ASCII repertoire.
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let geocodingResponse: GeocodingResponse = try await request(geocoding.url!)
        guard let location = geocodingResponse.results?.first else {
            throw WeatherSyncError.cityNotFound
        }

        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let forecastResponse: ForecastResponse = try await request(forecast.url!)
        guard let current = forecastResponse.current,
              current.temperature2m.isFinite,
              current.weatherCode >= 0, current.weatherCode <= 255 else {
            throw WeatherSyncError.invalidResponse
        }
        let tenths = Int((current.temperature2m * 10).rounded())
        guard tenths >= Int(Int16.min), tenths <= Int(Int16.max) else {
            throw WeatherSyncError.invalidResponse
        }
        return WeatherSnapshot(
            city: location.name,
            temperatureTenthsCelsius: Int16(tenths),
            weatherCode: UInt8(current.weatherCode)
        )
    }

    private func request<Value: Decodable>(_ url: URL) async throws -> Value {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw WeatherSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherSyncError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private struct GeocodingResponse: Decodable {
    let results: [Location]?

    struct Location: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
    }
}

private struct ForecastResponse: Decodable {
    let current: Current?

    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
}
