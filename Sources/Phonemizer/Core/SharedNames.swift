import Foundation

/// Month, weekday and time words, shared by the rules that read dates and times and by those
/// that must leave them alone: dates' own rules, the meridiem rule's full-stop test, the
/// `FullStop` test, and addresses' "St." before a day or month ("Liverpool St. Monday").
enum CalendarNames {
    static let months = ["jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May",
                         "jun": "June", "jul": "July", "aug": "August", "sep": "September", "sept": "September",
                         "oct": "October", "nov": "November", "dec": "December"]
    static let monthsInOrder = ["January", "February", "March", "April", "May", "June", "July", "August",
                                "September", "October", "November", "December"]

    /// Capitalised words that name a day, a month or a time zone: after an abbreviation's
    /// period they continue the sentence ("9 a.m. Monday", "1 Dec. Tuesday") rather than start one.
    static let timeWords = Set(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Mon",
                                "Tue", "Tues", "Wed", "Thu", "Thurs", "Fri", "Sat", "Sun", "Eastern", "Pacific",
                                "Central", "Mountain", "Atlantic", "Standard", "Daylight", "Time", "Local",
                                "Greenwich", "Coordinated", "Universal"] + monthsInOrder + months.keys.map(\.capitalized))
}

/// Currencies as the money pass reads and writes them, for rules that must leave money alone:
/// the measures pass doesn't take an amount as a size or a multiplier ("Buy 2 x $5 tickets",
/// "$2 x 3 = $6"), and by the time it runs the money pass has already written "5 dollars".
enum CurrencyNames {
    /// The signs the money pass reads before or after an amount.
    static let symbols: Set<Character> = ["$", "£", "€", "¥", "₹", "₩", "¢"]
    /// The words the money pass and the lexicon write after an amount, singular and plural.
    static let words: Set<String> = [
        "dollar", "dollars", "cent", "cents", "pound", "pounds", "pence", "penny", "euro", "euros", "yen", "sen",
        "rupee", "rupees", "paisa", "paise", "won", "jeon",
    ]
}
