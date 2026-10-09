import Foundation

/// The words the Roman pass (`RomanPass`) reads a numeral by: the titles, names, keywords and
/// franchises before it, and the words after a lone "I" that make it a number. All lower case,
/// matched against the word as written in title case or capitals (a keyword's lower-case form
/// counts only where a rule says so).
enum RomanNames {
    /// R2-A: titles before 1 to 3 names and a numeral ("Queen Elizabeth II", "Pope John Paul
    /// II"). After a restricted one, the first name must be a ruler's (`regnalNames`): "Duke
    /// Nukem II" is a game and "Prince Harry I moved" the pronoun.
    static let regnalTitles: [String: Bool] = [
        "king": false, "queen": false, "pope": false, "emperor": false, "empress": false, "tsar": false, "czar": false,
        "tsarina": false, "kaiser": false, "sultan": false, "pharaoh": false, "shah": false,
        "prince": true, "princess": true, "duke": true, "duchess": true, "archduke": true, "saint": true, "st.": true,
    ]

    /// R2-B: rulers' and popes' names, read as ordinals without a title ("Henry VIII", "Louis
    /// XIV", "Henry the VIII").
    static let regnalNames: Set<String> = [
        "henry", "edward", "george", "william", "charles", "james", "richard", "john", "elizabeth", "mary", "anne",
        "victoria", "louis", "philip", "philippe", "felipe", "ferdinand", "frederick", "friedrich", "wilhelm", "ludwig",
        "leopold", "francis", "franz", "joseph", "peter", "ivan", "nicholas", "alexander", "catherine", "paul", "pius",
        "leo", "gregory", "benedict", "clement", "innocent", "urban", "boniface", "sixtus", "julius", "adrian", "alfonso",
        "juan", "carlos", "gustav", "gustavus", "carl", "christian", "frederik", "haakon", "olav", "harald", "rama",
        "ramesses", "ramses", "thutmose", "amenhotep", "constantine", "justinian", "otto", "rudolf", "albert", "napoleon",
        "mehmed", "suleiman", "selim", "murad", "abdullah", "hussein", "faisal", "darius", "xerxes", "cyrus", "ptolemy",
        "malcolm", "david", "robert", "alfred", "edmund", "harold", "stephen", "pedro", "manuel", "sancho", "casimir",
        "sigismund", "vladimir", "matthias", "maximilian", "umberto", "emmanuel", "isabella", "isabel", "margaret",
        "margrethe", "christina", "rainier", "baudouin", "willem", "amadeus", "michael", "thomas", "daniel", "martin",
        "cleopatra", "arsinoe", "berenice", "antiochus", "seleucus", "philippa", "matilda", "jadwiga",
    ]
    /// Words after a ruler's name and a lone "I" that make it the First, where the pronoun can't
    /// follow a name without a comma ("Charles I was executed", "Peter I founded St.
    /// Petersburg", "Queen Mary I burned…"). Only when the name opens its sentence or has a title.
    static let regnalFollowers: Set<String> = [
        "was", "is", "had", "has", "ruled", "reigned", "died", "founded", "married", "became", "burned", "burnt", "built",
        "signed", "succeeded", "inherited", "invaded", "conquered", "defeated", "fought", "led", "ordered", "established",
        "created", "granted", "issued", "introduced", "abolished", "executed", "crowned", "came", "took", "made", "sent",
        "lost", "won", "moved", "ascended", "abdicated", "commissioned", "decreed", "expelled", "launched", "united",
        "of", "and",
    ]

    /// R2-C: given names before a family name and its suffix ("Thurston Howell III", "John D.
    /// Rockefeller IV"). Common first names, without those that are also ordinary words
    /// (Major, King, Prince, Duke, Royal, Hunter, Chase, Mark, Will, Grant, Rose…): "Major
    /// League II" is a film. Also keeps R8b's general sequel reading off a name ("Thurston III").
    static let givenNames: Set<String> = [
        // Men's names.
        "aaron", "abraham", "adam", "adrian", "alan", "albert", "alexander", "alfred", "allen", "alvin", "ambrose",
        "andrew", "angelo", "anthony", "antonio", "archibald", "archie", "arnold", "arthur", "augustus", "austin",
        "barry", "benjamin", "bennett", "bernard", "bertram", "bradford", "bradley", "brandon", "brian", "bruce",
        "bryan", "byron", "calvin", "carl", "carlos", "carlton", "cecil", "chad", "charles", "chester", "christopher",
        "clarence", "claude", "clayton", "clifford", "clifton", "clinton", "clyde", "cody", "colin", "conrad",
        "cornelius", "craig", "curtis", "cyrus", "dale", "damon", "daniel", "darrell", "darren", "david", "dennis",
        "derek", "dewey", "dexter", "donald", "douglas", "duane", "dudley", "dustin", "dwight", "edgar", "edmund",
        "edward", "edwin", "elbert", "eli", "elijah", "elliott", "ellis", "elmer", "emmett", "eric", "ernest",
        "eugene", "everett", "ezra", "felix", "fitzgerald", "floyd", "francis", "franklin", "fred", "frederick",
        "gabriel", "garrett", "gary", "gavin", "geoffrey", "george", "gerald", "gilbert", "glenn", "gordon", "graham",
        "gregory", "harold", "harrison", "harry", "harvey", "henry", "herbert", "herman", "horace", "howard", "hubert",
        "hugh", "hugo", "ian", "isaac", "ivan", "jacob", "james", "jason", "jasper", "jeffrey", "jeremiah", "jeremy",
        "jerome", "jesse", "joel", "john", "johnny", "jonathan", "jordan", "joseph", "joshua", "julian", "julius",
        "justin", "keith", "kenneth", "kevin", "kyle", "lamar", "lawrence", "leon", "leonard", "leroy", "leslie",
        "lester", "lewis", "lloyd", "louis", "lucas", "luke", "luther", "lyle", "marcus", "mario", "marion", "martin",
        "marvin", "matthew", "maurice", "maxwell", "melvin", "michael", "milton", "mitchell", "montgomery", "morgan",
        "morris", "nathan", "nathaniel", "neil", "nelson", "nicholas", "noah", "norman", "oliver", "oscar", "otis",
        "owen", "patrick", "paul", "percy", "perry", "peter", "philip", "phillip", "preston", "quentin", "ralph",
        "randall", "randolph", "raymond", "reginald", "richard", "robert", "roderick", "rodney", "roger", "roland",
        "ronald", "roscoe", "ross", "roy", "russell", "ryan", "samuel", "scott", "sebastian", "seth", "sidney",
        "simon", "solomon", "spencer", "stanley", "stephen", "steven", "stuart", "sylvester", "terrence", "theodore",
        "thomas", "thurston", "timothy", "todd", "travis", "trevor", "troy", "tyler", "vernon", "victor", "vincent",
        "wallace", "walter", "warren", "wayne", "wesley", "wilbur", "willard", "william", "willie", "winston",
        "zachary", "ben", "bill", "cal", "dan", "dave", "dean", "ed", "frank", "greg", "jack", "jim", "joe", "jon",
        "ken", "larry", "matt", "mike", "nick", "pete", "phil", "ray", "ron", "sam", "steve", "ted", "tim", "tom", "tony",
        // Women's names.
        "abigail", "alice", "alexandra", "amanda", "amelia", "amy", "andrea", "angela", "anna", "anne", "barbara",
        "beatrice", "betty", "beverly", "brenda", "caroline", "carolyn", "catherine", "charlotte", "christina",
        "christine", "claire", "clara", "cynthia", "deborah", "diana", "diane", "donna", "doris", "dorothy", "edith",
        "eleanor", "elizabeth", "ella", "ellen", "emily", "emma", "esther", "evelyn", "florence", "frances", "gloria",
        "hannah", "harriet", "helen", "irene", "isabella", "jacqueline", "jane", "janet", "jennifer", "jessica", "joan",
        "josephine", "joyce", "judith", "julia", "karen", "katherine", "kathleen", "laura", "lauren", "linda", "lisa",
        "louise", "lucy", "margaret", "maria", "marie", "martha", "mary", "megan", "melissa", "michelle", "nancy",
        "natalie", "nicole", "olivia", "pamela", "patricia", "rachel", "rebecca", "ruth", "sarah", "sharon", "sophia",
        "stephanie", "susan", "teresa", "victoria", "virginia", "wendy",
    ]

    /// R4 keywords before a numeral, by kind: a document part, a class or stage, or an event
    /// (Super Bowl is matched by "bowl" after "super"). Plurals take a list ("Chapters I–III").
    /// A list after a ruler's numeral is read as rulers ("Louis XIV, XV and XVI": `ruler`, which
    /// no keyword has).
    enum Kind { case document, grade, event, ruler }
    static let keywords: [String: Kind] = {
        var k: [String: Kind] = [:]
        for w in ["chapter", "chapters", "part", "parts", "book", "books", "volume", "volumes", "canto", "cantos", "title",
                  "titles", "article", "articles", "section", "sections", "schedule", "schedules", "annex", "appendix",
                  "table", "tables", "plate", "psalm", "psalms", "amendment", "episode", "episodes", "act", "acts",
                  "scene", "scenes", "page", "pages", "unit", "lesson", "module", "ch.", "vol.", "pp.", "p."] { k[w] = .document }
        for w in ["phase", "phases", "type", "types", "stage", "stages", "class", "classes", "level", "levels", "grade",
                  "grades", "tier", "tiers", "category", "division", "factor", "option", "options"] { k[w] = .grade }
        for w in ["bowl", "vatican", "apollo", "mark", "mk", "mk."] { k[w] = .event }
        return k
    }()

    /// Abbreviated keywords, written out before a numeral ("Ch. IV" → "Chapter four").
    static let expansions = ["ch.": "Chapter", "vol.": "Volume", "mk": "Mark", "mk.": "Mark", "pp.": "pages", "p.": "page"]

    /// Keywords after which a single X is ten ("Title X", "Super Bowl X"); after the others it's
    /// a letter ("Mark X on the map", "Type X").
    static let tenKeywords: Set<String> = [
        "chapter", "chapters", "ch.", "part", "parts", "book", "books", "volume", "volumes", "vol.", "title", "titles",
        "article", "articles", "canto", "cantos", "psalm", "psalms", "bowl", "apollo",
    ]

    /// R7: keywords whose numeral can carry a sub-stage letter ("Stage IIIA", "Class IIb").
    static let subStageKeywords: Set<String> = [
        "stage", "stages", "phase", "phases", "type", "types", "class", "classes", "grade", "grades",
    ]

    /// R13 (2): third-person verbs, which the pronoun "I" can't take ("Table I shows the results").
    static let thirdPersonVerbs: Set<String> = [
        "shows", "lists", "covers", "describes", "summarizes", "summarises", "presents", "contains", "includes", "gives",
        "explains", "introduces", "outlines", "compares", "reports", "provides", "establishes", "begins", "ends",
        "deals", "focuses", "discusses", "examines", "defines",
    ]

    /// R13 (3): words after a keyword's "I" that make it a number ("Schedule I drug", "Level I
    /// trauma center"); anything else keeps the pronoun ("Mark I disagree", "Part I agree").
    static let followers: [String: Set<String>] = {
        let lists: [String: Set<String>] = [
            "phase": ["trial", "trials", "study", "studies", "clinical", "starts", "begins", "ends", "is", "was", "will", "runs"],
            "type": ["diabetes", "diabetic", "error", "errors", "collagen", "hypersensitivity", "supernova", "supernovae"],
            "stage": ["cancer", "disease", "tumor", "tumour", "breast", "lung", "colon", "colorectal", "prostate",
                      "ovarian", "cervical", "skin", "melanoma", "lymphoma", "hypertension"],
            "class": ["recall", "recalls", "device", "devices", "obesity"],
            "level": ["trauma", "certification"],
            "grade": ["listed"],
            "schedule": ["drug", "drugs", "substance", "substances", "narcotic", "narcotics"],
            // "Episode I was released", "Phase I starts Monday", "Option I is faster": the
            // pronoun never follows these words without a comma.
            "episode": ["was", "is", "came", "comes", "opened", "opens", "premiered", "premieres", "aired", "airs", "starts", "begins"],
            "option": ["is", "was", "would", "will", "costs", "gives", "means", "requires", "works", "seems"],
            "title": ["funding", "funds", "school", "schools", "program", "programs"],
            "division": ["school", "schools", "college", "colleges", "athlete", "athletes", "football", "basketball",
                         "program", "programs", "team", "teams"],
        ]
        var all = lists
        for (plural, singular) in ["phases": "phase", "types": "type", "stages": "stage", "classes": "class",
                                   "levels": "level", "grades": "grade", "schedules": "schedule", "titles": "title"] {
            all[plural] = lists[singular]
        }
        return all
    }()

    /// R2: nouns after "IV" that make it intravenous ("give John IV fluids").
    static let clinicalNouns: Set<String> = [
        "fluid", "fluids", "antibiotic", "antibiotics", "access", "line", "lines", "drip", "push", "iron", "contrast",
        "dose", "doses",
    ]

    /// R1: words after "the World War I" that keep it the war ("the World War I centenary");
    /// before any other word it's the pronoun of 1920s prose ("During the World War I served").
    static let worldWarOneNouns: Set<String> = [
        "memorial", "era", "centenary", "centennial", "armistice", "generation", "veteran", "veterans", "poet", "poets",
        "poetry", "trenches", "years", "soldier", "soldiers", "museum", "battlefield", "battlefields", "cemetery",
        "monument", "history",
    ]

    /// R8a: franchises whose numbers include the ones R8b leaves alone (IV, XI, XV, a single V
    /// or X), as their words in lower case, with the highest number each takes.
    static let franchises: [(words: [String], highest: Int)] = [
        (["rocky"], 39), (["rambo"], 39), (["creed"], 39), (["superman"], 39), (["godfather"], 39),
        (["star", "trek"], 39), (["final", "fantasy"], 39), (["dragon", "quest"], 39), (["kingdom", "hearts"], 39),
        (["street", "fighter"], 39), (["mortal", "kombat"], 39), (["diablo"], 39), (["warcraft"], 39),
        (["starcraft"], 39), (["civilization"], 39), (["age", "of", "empires"], 39), (["hearts", "of", "iron"], 39),
        (["europa", "universalis"], 39), (["crusader", "kings"], 39), (["dark", "souls"], 39),
        (["baldur's", "gate"], 39), (["baldur’s", "gate"], 39), (["elder", "scrolls"], 39), (["hades"], 39),
        (["doom"], 39), (["quake"], 39), (["halloween"], 39), (["psycho"], 39), (["saturn"], 5),
        (["grand", "theft", "auto"], 39), (["wrestlemania"], 89),
    ]

    /// R10: rugby sides whose "XV" is the team ("The England XV"), not a model ("Subaru XV").
    static let rugbySides: Set<String> = ["england", "scotland", "wales", "ireland", "france", "italy", "lions", "barbarians"]
    /// R10: words before a team's XI or XV ("the starting XI").
    static let elevenWords: Set<String> = ["starting", "first", "second", "third", "playing", "best", "combined"]
    static let fifteenWords: Set<String> = ["starting", "unchanged", "matchday"]
}
