import Foundation

/// The words around a unit that decide what it is, for the unit rules' context checks
/// (`UnitRules`, `UnitSpot`). All lower case unless a list says otherwise; a rule compares them
/// with the sentence's words, read with the custom lexicon's marks as their labels.
enum UnitWords {
    // MARK: Spaced and glued m

    /// After a spaced "m", words that make it minutes or millions: "5 m ago", "3 m left".
    static let notMeters: Set<String> = ["ago", "left", "late", "later", "early", "remaining"]
    /// Things counted in millions: "3 m viewers", "2 m downloads".
    static let countNouns: Set<String> = [
        "people", "users", "viewers", "customers", "subscribers", "followers", "members", "residents", "voters", "votes",
        "visitors", "downloads", "views", "streams", "copies", "units", "jobs", "homes", "households", "years",
        "barrels", "dollars", "pounds", "euros", "savers", "fans", "listeners", "readers", "students", "workers", "employees",
        "passengers", "tickets", "subscriptions", "accounts", "players", "patients", "cases", "deaths", "doses", "tonnes",
        "tons", "trees", "steps", "likes", "plays", "installs", "orders", "transactions", "messages", "emails", "visits",
        "shares", "devices", "cars", "vehicles", "books", "songs", "albums", "apps", "migrants", "refugees", "children",
        "pensioners", "claimants", "motorists", "tourists", "adults", "citizens", "immigrants", "taxpayers", "borrowers",
        "homeowners", "renters", "tenants", "drivers", "smokers", "consumers", "shoppers", "families", "britons",
        "americans", "babies", "animals", "birds", "items", "parcels", "packages", "calls", "applications", "claims",
        "signatures", "reviews", "teams", "companies", "businesses", "firms", "properties", "beds", "vaccines", "tests",
    ]
    /// What a decimal "m" measures before it, said "meter": "1.5m strips", "two 2.4m boards".
    /// Anything else stays as written: before most plurals "m" is as often millions ("4.5m
    /// pensioners"), and "3M hooks" is a brand.
    static let lengthNouns: Set<String> = [
        "strip", "strips", "board", "boards", "length", "lengths", "plank", "planks", "beam", "beams", "pole", "poles",
        "post", "posts", "rail", "rails", "pipe", "pipes", "cable", "cables", "rope", "ropes", "hose", "hoses", "roll",
        "rolls", "batten", "battens", "rod", "rods", "ladder", "ladders",
    ]
    /// A baby's clothes, whose sizes count months: "12M pajamas", "18M onesies".
    static let babyClothes: Set<String> = [
        "pajamas", "pyjamas", "onesie", "onesies", "bodysuit", "bodysuits", "romper", "rompers", "sleeper", "sleepers",
        "sleepsuit", "sleepsuits", "babygrow", "babygrows", "outfit", "outfits", "clothes", "leggings",
    ]
    /// Plurals without an "s": "1.2m people".
    static let irregularPlurals: Set<String> = ["people", "children", "men", "women", "staff", "folks"]
    /// After k or K, a race or a screen, not thousands: "5k runs", "8K displays".
    static let raceNouns: Set<String> = ["run", "runs", "race", "races", "runner", "runners", "walk", "walks", "swim", "swims"]
    static let raceWords: Set<String> = ["marathon", "jog", "jogging", "parkrun", "running", "race"]
    static let screenNouns: Set<String> = [
        "displays", "monitors", "screens", "tvs", "televisions", "videos", "cameras", "panels", "projectors", "resolutions",
    ]

    /// A sentence about money or people counts its m in millions ("raised 5 m").
    static let moneyWords: Set<String> = [
        "raised", "revenue", "funding", "budget", "sales", "profit", "valuation", "worth", "deal", "debt", "population",
    ]
    /// The only words a glued "m" is meters before ("30m high", "2m apart"): elsewhere "5m" is
    /// as often minutes or millions ("I'm 5m away", "the 100m final" stays as written).
    static let sizeWords: Set<String> = [
        "tall", "high", "long", "deep", "wide", "thick", "apart", "across", "below", "above", "underwater",
    ]

    /// Before a unit, words that make a number with a letter after it a measurement: "more
    /// than 2s", "about 3s".
    static let comparisons: Set<String> = ["than", "about", "around", "nearly", "almost", "within"]
    /// "under" and "over" only after one of these ("loads in under 3s", "a time of just over
    /// 9s"): "Over 65s will lose…" and "for under 5s" are age groups.
    static let timedBefore: Set<String> = [
        "in", "just", "only", "of", "took", "takes", "take", "taking", "lasted", "lasts", "ran", "runs", "finished", "loads",
        "loaded", "clocked", "timed",
    ]

    // MARK: Stone, hectares and temperatures

    /// A sentence about weight, where st is stone: "He weighs 12 st", "Lost 2 st".
    static let weightWords: Set<String> = [
        "weigh", "weighs", "weighed", "weighing", "weight", "weights", "lost", "lose", "losing", "loses", "gained", "gain",
        "gaining", "gains", "heavier", "lighter", "diet", "dieting", "scales", "slimming", "overweight", "obese", "bmi",
    ]
    /// A sentence about land, where ha is hectares.
    static let landWords: Set<String> = [
        "acres", "acre", "hectares", "land", "forest", "forests", "farm", "farms", "farmland", "burned", "burnt", "wildfire",
        "wildfires", "fire", "fires", "estate", "park", "reserve", "plantation", "plantations", "plot", "crops", "vineyard",
        "woodland", "deforestation", "cleared",
    ]
    /// A sentence about heat or the weather, where a C or F after a number is a temperature.
    static let temperatureWords: Set<String> = [
        "temperature", "temperatures", "temp", "temps", "degrees", "heat", "heatwave", "hot", "hotter", "hottest", "cold",
        "colder", "coldest", "cool", "cooler", "warm", "warmer", "warmest", "freezing", "frost", "chilly", "mild", "weather",
        "forecast", "highs", "lows", "sunny", "cloudy", "rain", "snow", "humid", "humidity", "oven", "preheat", "fever",
        "thermometer", "scorching", "sweltering",
    ]

    /// Words before a glued g that make it grams, though they label it ("Carbs 30g", "Trans Fat
    /// 0g"), and that make a "5g" the lexicon took for the network grams ("Sugar 5g per bar").
    static let nutrients: Set<String> = [
        "fat", "fats", "carbs", "carb", "carbohydrate", "carbohydrates", "protein", "proteins", "sugar", "sugars", "fiber",
        "fibre", "salt", "sodium", "saturates", "saturated", "sat", "trans", "starch", "alcohol", "net",
    ]

    // MARK: pt, pc, bp, pp

    /// A sentence about a drink or cooking, where pt is pints: "1 pt. heavy cream".
    static let drinkWords: Set<String> = ["milk", "cream", "water", "beer", "ale", "lager", "stout", "cider", "stock", "broth", "juice", "wine"]
    /// A sentence in a clinic, where "12 pt" are patients.
    static let clinicWords: Set<String> = ["patient", "patients", "clinic", "ward", "wards", "nurse", "nurses", "hospital", "admitted", "admissions"]
    /// After a glued "pc", a piece rather than per cent: "a 3pc suit".
    static let pieceNouns: Set<String> = [
        "set", "sets", "suit", "suits", "kit", "kits", "bucket", "buckets", "nuggets", "meal", "meals", "sectional", "dining",
        "cookware", "tool", "luggage", "puzzle", "bedroom", "patio", "knife", "pan",
    ]
    /// A sentence about a connection, where bps is bits per second.
    static let connectionWords: Set<String> = [
        "modem", "baud", "connection", "bandwidth", "download", "upload", "network", "link", "internet", "wifi", "transfer", "serial",
    ]
    /// A sentence about a document, where pp are pages: "The Q2 board deck is 40 pp.".
    static let documentWords: Set<String> = [
        "deck", "decks", "report", "reports", "book", "books", "document", "documents", "paper", "papers", "pages", "page",
        "chapter", "chapters", "pdf", "slides", "appendix", "manuscript", "thesis", "dissertation", "hardcover", "hardback",
        "paperback", "booklet", "brochure", "manual", "handbook", "volume", "journal", "proposal", "draft", "memo", "essay",
        "pamphlet", "dossier", "brief", "printout",
    ]

    // MARK: TB and gal

    /// "650 TB deaths": nouns after TB that make it tuberculosis.
    static let diseaseNouns: Set<String> = [
        "deaths", "death", "cases", "case", "patients", "patient", "infections", "infection", "rates", "rate", "drugs", "drug",
        "treatment", "treatments", "vaccine", "vaccines", "test", "tests", "testing", "screening", "clinic", "clinics",
        "outbreak", "outbreaks", "incidence", "notifications", "diagnoses", "programme", "program", "sufferers", "burden",
    ]
    /// Words in TB's sentence that make it tuberculosis.
    static let diseaseWords: Set<String> = ["tuberculosis", "disease", "infected", "diagnosed", "hiv", "malaria", "epidemic"]
    /// "3 gal pals": nouns after "gal" that make it a friend.
    static let galNouns: Set<String> = ["pal", "pals", "friend", "friends", "squad", "gang", "crew"]

    // MARK: g

    /// A glued 2 to 6 with these is a mobile network ("4g in the village", "the 5g rollout").
    static let networkWords: Set<String> = [
        "phone", "signal", "network", "coverage", "mobile", "data", "lte", "sim", "carrier", "reception", "wifi",
        "internet", "connection", "rollout", "mast", "tower", "broadband", "router", "hotspot",
    ]
    /// With these, g is g-force ("pull 9 g"); with any word starting "pull" too.
    static let gForceWords: Set<String> = [
        "force", "forces", "pilot", "jet", "fighter", "aircraft", "coaster", "rollercoaster", "crash", "impact",
        "acceleration", "centrifuge", "astronaut",
    ]

    // MARK: L

    /// A glued L after 30 to 60 before these is Long: "a 42L suit jacket".
    static let suitWords: Set<String> = ["suit", "suits", "jacket", "jackets", "blazer", "blazers", "coat", "coats"]
    /// Who a glued 1L to 4L after them is (a law student: "As a 1L", "She's a 2L").
    static let lawStudentOwners: Set<String> = ["a", "my", "her", "his", "every", "our", "their", "your"]
    /// Unless a container or a drink follows: "a 2L bottle of soda".
    static let containers: Set<String> = [
        "bottle", "bottles", "jug", "jugs", "carton", "cartons", "tank", "tanks", "flask", "flasks", "pot", "pots", "pan",
        "pans", "of", "soda", "water", "juice", "milk",
    ]

    // MARK: W and A

    /// Capitalised words a W before them is still watts: "65 W USB-C charger". Case as written.
    static let wattNames: Set<String> = [
        "LED", "LEDs", "USB", "USB-C", "AC", "DC", "RMS", "PSU", "GaN", "PD", "Qi", "MagSafe", "CFL", "PoE",
    ]
    /// A capital A after a number is amps only with these in its sentence: "Fit a 13 A fuse".
    /// Not "current", "rated", "battery", "load", "plug" or "cable": each has a common other
    /// sense ("current tally is 5 A", "rated 12A", "a battery of exams").
    static let electricalWords: Set<String> = [
        "volt", "volts", "voltage", "watt", "watts", "amp", "amps", "ampere", "amperes", "amperage", "fuse", "fuses",
        "breaker", "breakers", "circuit", "circuits", "charger", "chargers", "charging", "socket", "sockets", "outlet",
        "outlets", "adapter", "adaptor", "inverter", "psu", "usb", "wiring", "electric", "electrical",
    ]

    // MARK: h

    /// Before a clock hour ("until 18h", "at 9h"): European time, not a duration.
    static let clockWords: Set<String> = ["at", "until", "till", "from", "by", "before", "after"]

    // MARK: Table units

    /// hp in a game is hit points: "The potion heals 50 hp".
    static let gameWords: Set<String> = [
        "heal", "heals", "healing", "damage", "potion", "potions", "boss", "enemy", "enemies", "player", "players", "mana",
        "xp", "health",
    ]
    /// With "10k gold", the gold is a game's ("I farmed 10k gold"), never carats.
    static let gameGoldWords: Set<String> = [
        "game", "games", "gaming", "coin", "coins", "farm", "farmed", "farming", "loot", "quest", "quests", "raid",
        "raids", "grind", "grinding", "player", "players", "guild", "server",
    ]
    /// atm is atmospheres only with these: alone it's chat for "at the moment".
    static let pressureWords: Set<String> = [
        "pressure", "psi", "bar", "pa", "gas", "tank", "dive", "diving", "depth", "vacuum", "boil", "boils", "boiled",
        "boiling", "atmosphere", "atmospheres",
    ]
    /// MW on the radio is medium wave: "Tune to 909 MW". "AM" and "FM" are checked as written.
    static let radioWords: Set<String> = ["radio", "khz", "station", "tune", "tuned", "frequency", "wavelength"]
    /// ppm on a printer is pages per minute: "20 ppm in color" (and any word starting "print" or "scan").
    static let printWords: Set<String> = ["pages", "page"]
    /// nm near these is nautical miles ("12 nm offshore"), and kn is knots, not kuna.
    static let seaWords: Set<String> = [
        "offshore", "ship", "ships", "boat", "boats", "vessel", "vessels", "yacht", "yachts", "ferry", "sail", "sails",
        "sailed", "sailing", "harbour", "harbor", "coast", "coastline", "nautical", "knot", "knots", "kts", "aircraft",
        "flight", "flights", "flew", "fly", "flying", "plane", "planes", "airport", "runway", "pilot", "pilots",
    ]
    /// kt is knots with these: "15 kt winds".
    static let windWords: Set<String> = [
        "wind", "winds", "gust", "gusts", "gusting", "breeze", "headwind", "tailwind", "crosswind", "airspeed",
        "groundspeed", "sea", "seas", "boat", "ship", "vessel", "aircraft",
    ]
    /// The nouns knots measure, said with a singular before them: "15 knot winds".
    static let windNouns: Set<String> = ["wind", "winds", "gust", "gusts", "breeze", "headwind", "tailwind", "crosswind"]
    /// But kt near these is kilotons: "a yield of 21 kt".
    static let blastWords: Set<String> = [
        "bomb", "bombs", "nuclear", "warhead", "warheads", "yield", "blast", "explosion", "explosions", "tnt",
    ]
    /// pt is pints before these (and "of").
    static let pintWords: Set<String> = [
        "of", "milk", "cream", "water", "beer", "ale", "lager", "stout", "cider", "stock", "broth", "juice",
    ]
    /// pt is points before these: "12 pt type", "a 3 pt shot".
    static let pointWords: Set<String> = [
        "type", "typeface", "font", "text", "size", "lettering", "leading", "line", "lines", "margin", "stroke", "border",
        "gutter", "serif", "sans", "bold", "italic", "regular", "lead", "deficit", "scale", "shot", "turn", "plan",
    ]
    /// A lower-case "m2"/"m3" is square or cubic meters before these, or punctuation: "a 50 m2 flat".
    static let areaNouns: Set<String> = [
        "flat", "apartment", "house", "home", "office", "room", "plot", "space", "garden", "of", "per",
    ]
    /// But not in a sentence about M.2 drives: "2 m2 slots". Case as written.
    static let driveWords: Set<String> = ["slot", "slots", "SSD", "SSDs", "NVMe", "drive", "drives", "chip", "Mac", "MacBook"]
}
