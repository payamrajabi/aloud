import Foundation

/// The word lists of the titles pass (Core readings, FIN-889; titles.json): which abbreviation
/// reads as which title, the words that stop a title from expanding, and the words that give an
/// abbreviation another reading. Every list is matched case-sensitively unless its comment says
/// otherwise.
extension TitlePass {
    /// Ranks and offices written with a period, read only before a name (T2), and their plurals.
    /// "Off." (Lights Off.) and "M." (an initial far more often than Monsieur) are left out.
    static let titles: [String: String] = [
        "Lt": "Lieutenant", "Capt": "Captain", "Col": "Colonel", "Maj": "Major", "Brig": "Brigadier", "Adm": "Admiral",
        "Cmdr": "Commander", "Cdr": "Commander", "Ens": "Ensign", "Sgt": "Sergeant", "Cpl": "Corporal", "Pvt": "Private",
        "Pte": "Private", "Pfc": "Private First Class", "Spc": "Specialist", "Det": "Detective", "Insp": "Inspector",
        "Supt": "Superintendent", "Ofc": "Officer", "Fr": "Father", "Msgr": "Monsignor", "Br": "Brother",
        "Hon": "Honorable", "Pres": "President", "Amb": "Ambassador", "Atty": "Attorney", "Sec": "Secretary",
        "Mx": "Mix", "Mme": "Madame", "Mlle": "Mademoiselle", "Sen": "Senator", "Gov": "Governor", "Prof": "Professor",
        "Gen": "General", "Rep": "Representative", "Rev": "Reverend",
        "Sens": "Senators", "Reps": "Representatives", "Govs": "Governors", "Gens": "Generals", "Sgts": "Sergeants",
        "Lts": "Lieutenants", "Capts": "Captains", "Cols": "Colonels", "Pvts": "Privates", "Cpls": "Corporals",
        "Dets": "Detectives", "Profs": "Professors", "Revs": "Reverends", "Drs": "Doctors",
    ]

    /// UK newsroom titles written without a period, read before a name (T4a). The others never
    /// expand without one (T4d: "Gen Alpha", "Brig Niagara", "Hon Hai", "Col du Galibier"), except
    /// "Col" and "Maj" before a first name and a surname (T4c) and "the Rev" before a name.
    static let bareTitles: [String: String] = [
        "Lt": "Lieutenant", "Capt": "Captain", "Cpl": "Corporal", "Pte": "Private", "Sgt": "Sergeant",
        "Cdr": "Commander", "Cmdr": "Commander", "Insp": "Inspector", "Supt": "Superintendent",
        "Pfc": "Private First Class", "Revd": "Reverend", "Cllr": "Councillor", "Cllrs": "Councillors", "Mx": "Mix",
        "Mme": "Madame", "Mlle": "Mademoiselle", "Prof": "Professor", "Fr": "Father",
    ]

    /// Two titles read as one, with or without periods (T8, T4b). With a period they need no name
    /// after them ("The Lt. Gov. cast the deciding vote."); without one only the `namelessPairs`
    /// do. A title before another title also expands on its own ("Det. Chief Insp. Barnaby").
    static let pairs: [String: String] = [
        "Lt Col": "Lieutenant Colonel", "Lt Gen": "Lieutenant General", "Lt Gov": "Lieutenant Governor",
        "Lt Cdr": "Lieutenant Commander", "Lt Cmdr": "Lieutenant Commander", "Maj Gen": "Major General",
        "Brig Gen": "Brigadier General", "Atty Gen": "Attorney General", "Sec Gen": "Secretary General",
        "Flt Lt": "Flight Lieutenant", "Sqn Ldr": "Squadron Leader", "Wg Cdr": "Wing Commander",
        "Gp Capt": "Group Captain", "Ch Supt": "Chief Superintendent", "Ch Insp": "Chief Inspector",
        "Det Insp": "Detective Inspector", "Det Sgt": "Detective Sergeant", "Det Supt": "Detective Superintendent",
        "Rt Hon": "Right Honourable", "Rt Rev": "Right Reverend", "Rt Revd": "Right Reverend",
        "Treas Sec": "Treasury Secretary", "Hon Sec": "Honorary Secretary", "Hon Treas": "Honorary Treasurer",
        "Sgt Maj": "Sergeant Major", "Pvt Ltd": "Private Limited", "Pte Ltd": "Private Limited",
    ]
    /// The police ranks of three: "Det Ch Supt", "Det. Ch. Insp.".
    static let triples: [String: String] = [
        "Det Ch Supt": "Detective Chief Superintendent", "Det Ch Insp": "Detective Chief Inspector",
    ]
    /// Pairs that expand without periods and without a name: a company suffix, a club officer.
    static let namelessPairs: Set<String> = ["Pvt Ltd", "Pte Ltd", "Treas Sec", "Hon Sec", "Hon Treas"]
    /// The words in the pairs and triples that open one but are no title alone ("Flt 22", "Rt 66").
    static let pairOpeners: Set<String> = ["Flt", "Sqn", "Wg", "Gp", "Ch", "Rt", "Treas"]
    /// Titles joined to "-elect" (T8): "Gov.-elect Spanberger".
    static let electTitles: Set<String> = ["Gov", "Pres", "Sen", "Rep"]

    /// Titles with a period that count as the name after another title, so a chain expands ("Lt.
    /// Col. Ramirez", "Rev. Dr. King"). Any other word ending in "." stops it ("Phys. Rev. Lett.",
    /// "Ofc. Mgr.", "Br. J. Surg."), unless that period is the full stop.
    static let chainTitles: Set<String> = [
        "Lt", "Capt", "Col", "Gen", "Sgt", "Maj", "Cmdr", "Cdr", "Det", "Insp", "Supt", "Sec", "Gov", "Prof", "Rev",
        "Hon", "Dr", "Mr", "Mrs", "Ms",
    ]

    /// Next words that stop a title (T2): not a name, but the abbreviation's other meaning ("Col.
    /// Totals", "Amb. Glass Jar", "Pres. Day sale"). The abbreviation is then left as it is.
    static let skips: [String: Set<String>] = [
        "Lt": ["Arm", "Leg", "Knee", "Hip", "Hand", "Foot", "Eye", "Ear", "Shoulder", "Ankle", "Wrist", "Elbow", "Side",
               "Lung", "Kidney", "Breast"],
        "Col": ["Total", "Totals", "Width", "Header", "Name", "Springs"],
        "Brig": ["Combat", "Team", "HQ"],
        "Adm": ["Fee", "Fees", "Free", "Charge", "Price", "Ticket", "Tickets", "Assistant", "Office", "Staff", "Building",
                "Law", "Code", "Date"],
        "Amb": ["Temp", "Temperature", "Air", "Noise", "Light", "Glass", "Bottle", "Jar", "Service", "Crew", "Bay",
                "Surgery", "Care"],
        "Insp": ["Date", "Due", "Report", "Cert", "Certificate", "Sticker", "Fee", "Type", "Result", "Results", "Record",
                 "Form", "Status"],
        "Det": ["Limit", "Limits", "House", "Garage", "Bungalow"],
        "Ofc": ["Hours", "Supplies", "Space", "Phone", "Use", "Closed", "Open", "Manager", "Address", "Building",
                "Number", "Furniture", "Equipment", "Depot", "Staff", "Assistant"],
        "Fr": ["Fries", "Toast", "Onion", "Bread", "Dip", "Vanilla", "Roast", "Press", "Door", "Doors", "Polynesia",
               "Guiana", "Riviera", "Quarter", "Horn", "Open", "Revolution", "Canadian", "Sa", "Sat", "Su", "Sun"],
        "Br": ["Columbia", "Honduras", "Virgin", "Manager", "Office", "Library"],
        "Pres": ["Church", "Day", "Sensor", "Gauge", "Switch", "Valve", "Deck", "Slides", "Notes"],
        "Sec": ["Deposit", "Guard", "Code", "Level"],
        "Rev": ["Share", "Growth", "Limiter", "Counter", "Up"],
        "Prof": ["Development", "Services", "Liability"],
        // Clinical "Mx" is management ("Mx Plan agreed with the patient").
        "Mx": ["Plan", "Plans", "Options", "Strategy", "Protocol", "Pathway", "Guidelines", "Summary"],
    ]

    /// The other meaning some abbreviations have before a word that settles it, read instead of
    /// the title (T14 and titles.json's adopted open question): "Gov. Shutdown" is Government,
    /// "Hon. Doctorate" Honorary, "Fr. Fries" French, "Sec. Deposit" security, "Insp. Date"
    /// inspection. Matched in any case ("Hon. mention"). "Rev. Share", "Det. House" and "Lt. Knee"
    /// are only skipped: "rev share" is how people say it, and "left knee" is the medical pack's.
    static let plainReadings: [String: (words: Set<String>, reads: String)] = [
        "Gov": (["shutdown", "website", "site", "agency", "agencies", "contract", "contracts", "contractor",
                 "contractors", "funding", "grant", "grants", "job", "jobs", "official", "officials", "employee",
                 "employees", "worker", "workers", "data", "bond", "bonds", "debt", "spending", "program", "programs",
                 "programme", "policy", "id"], "Government"),
        "Hon": (["doctorate", "degree", "fellow", "fellowship", "lecturer", "consul", "life", "citizen", "chair",
                 "chairman", "president", "director", "advisor", "secretary", "treasurer"], "Honorary"),
        "Fr": (["fries", "toast", "onion", "bread", "dip", "vanilla", "roast", "press", "door", "doors", "polynesia",
                "guiana", "riviera", "quarter", "horn", "open", "revolution", "canadian"], "French"),
        "Sec": (["deposit", "guard", "code", "level"], "Security"),
        "Insp": (["date", "due", "report", "cert", "certificate", "sticker", "fee", "type", "result", "results", "record",
                  "form", "status"], "Inspection"),
    ]
    /// "Hon. mention" is a fixed phrase every reader expands (T14).
    static let mentions: Set<String> = ["mention", "mentions"]

    /// "Gen." as a generation (T3): before these, or after an ordinal or one of `generationAfter`.
    static let generations: Set<String> = ["X", "Y", "Z", "Alpha", "Beta"]
    /// Matched in any case.
    static let generationAfter: Set<String> = ["first", "second", "third", "fourth", "fifth", "next", "new", "last",
                                               "latest", "current", "previous", "prior", "older", "newer"]

    /// Ranks read with no name after them (T11), after one of `rankWords`: "promoted to Sgt.",
    /// "Ask the Capt.". Not Col. (column), Maj. (majority), Gen., Det., Sec., Insp. or Pres.; "Lt."
    /// only after "to" or "as" ("the Lt. version" is light).
    static let ranksAlone: Set<String> = ["Sgt", "Capt", "Cpl", "Pvt", "Pfc", "Spc", "Cmdr", "Supt"]
    /// Matched in any case.
    static let rankWords: Set<String> = ["the", "a", "to", "as", "our", "his", "her", "their", "my", "your", "new",
                                         "former", "then"]

    /// "Lt." as light (T9), before these (in any case): colours that aren't common names, and the
    /// hardware and coffee words.
    static let lightWords: Set<String> = ["blue", "pink", "purple", "yellow", "teal", "aqua", "beige", "khaki",
                                          "lavender", "turquoise", "peach", "orange", "lilac", "mint", "cream", "taupe",
                                          "duty", "wash", "roast"]
    /// Colours that are also first names, light only when no capitalised word follows the colour
    /// ("Lt. Olive Harper" is a lieutenant).
    static let nameColours: Set<String> = ["olive", "coral", "rose", "amber", "ruby", "jade", "hazel", "violet"]
    /// Colours that are also surnames ("Lt. Gray"), light only after "Color:" or "Colour:".
    static let surnameColours: Set<String> = ["gray", "grey", "green", "brown", "white", "black", "red", "gold",
                                              "silver", "tan"]
    /// The product-page label that settles "Lt." before any colour as light ("Color: Lt. Gray").
    static let colourLabels: Set<String> = ["Color:", "color:", "Colour:", "colour:", "Colors:", "colors:", "Colours:",
                                            "colours:"]

    /// Jobs and "senior" nouns that make "Sr." or "Snr" Senior when one of the next three
    /// capitalised words is one of them (T5b): "Sr. Vice President", "a Sr. Business Analyst",
    /// "Our Sr. Living community". Matched in any case.
    static let seniorWords: Set<String> = [
        "engineer", "engineers", "software", "product", "program", "project", "manager", "director", "vice", "vp",
        "analyst", "developer", "designer", "consultant", "associate", "accountant", "architect", "scientist",
        "researcher", "editor", "writer", "counsel", "partner", "lecturer", "fellow", "specialist", "officer", "advisor",
        "adviser", "executive", "producer", "staff", "principal", "pastor", "minister", "chaplain", "nurse",
        "technician", "administrator", "coordinator", "recruiter", "attorney", "buyer", "planner", "strategist", "lead",
        "living", "center", "centre", "citizen", "citizens", "discount", "housing", "care", "high", "year", "class",
        "varsity", "team", "management",
    ]
    /// Given names that make "Sr." Sister (T5c): "Sr. Mary Joseph", "Dear Sr. Helen". A nun with a
    /// name not listed keeps the letters, and so does Spanish "Sr. García" (Señor).
    static let sisterNames: Set<String> = [
        "Mary", "Marie", "Maria", "Helen", "Anne", "Ann", "Anna", "Catherine", "Katherine", "Kathleen", "Margaret",
        "Teresa", "Theresa", "Thérèse", "Therese", "Joan", "Rose", "Agnes", "Bernadette", "Clare", "Claire", "Frances",
        "Elizabeth", "Patricia", "Dorothy", "Monica", "Cecilia", "Josephine", "Bridget", "Brigid", "Veronica", "Lucy",
        "Martha", "Ruth", "Rita", "Angela", "Pauline", "Eileen", "Maureen", "Assumpta", "Benedicta", "Scholastica",
        "Siobhán", "Siobhan", "Niamh", "Bríd", "Brid", "Máire", "Maire", "Aoife", "Sinéad", "Sinead", "Áine", "Aine",
        "Mairéad", "Mairead", "Nuala", "Úna", "Una", "Deirdre", "Maeve",
    ]

    /// Jobs that make "Assoc." Associate and "Asst." Assistant (T7).
    static let assistedJobs: Set<String> = ["Prof", "Professor", "Dean", "Director", "Dir", "Editor", "Coach", "Manager",
                                            "Principal", "Chief", "Secretary", "Sec", "Attorney"]
}
