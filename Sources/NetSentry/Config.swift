import Foundation

public struct Config: Equatable {
    public var debounce: Debounce
    public var notifiers: Notifiers

    public struct Debounce: Equatable {
        public var seconds: Double
    }

    public struct Notifiers: Equatable {
        public var speech: Speech
        public var modal: Modal
        public var banner: Banner
    }

    public struct Speech: Equatable {
        public var enabled: Bool
        public var voice: String
        public var textDown: String
        public var textUp: String
    }

    public struct Modal: Equatable {
        public var enabled: Bool
        public var icon: String
        public var timeoutSeconds: Int
        public var textDown: String
        public var textUp: String
    }

    public struct Banner: Equatable {
        public var enabled: Bool
        public var title: String
        public var textDown: String
        public var textUp: String
    }

    public static let defaults = Config(
        debounce: Debounce(seconds: 2.0),
        notifiers: Notifiers(
            speech: Speech(
                enabled: true,
                voice: "Samantha",
                textDown: "Internet is down",
                textUp: ""
            ),
            modal: Modal(
                enabled: true,
                icon: "stop",
                timeoutSeconds: 30,
                textDown: "Internet is down",
                textUp: ""
            ),
            banner: Banner(
                enabled: true,
                title: "Net Sentry",
                textDown: "Internet is down",
                textUp: "Internet is back"
            )
        )
    )
}
