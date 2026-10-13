import Foundation

/// The names the address pass reads codes into, and the curated place lists that let it read a
/// state or province code with no postal code after it (DECISIONS 5).
///
/// Two letters after "City, " are a state only when the text settles it: a ZIP or postal code
/// follows, or the place is one we know is in that state. Other countries use the same letters
/// ("Chennai, TN" is Tamil Nadu, "Curitiba, PR" Paraná, "Monterrey, NL" Nuevo León), so an
/// unlisted town with no code after it stays as letters ("Marfa, TX"), a miss we accept. The
/// lists hold US cities of about 100,000 people or more, every state capital and each state's
/// largest city, with a few well-known smaller ones; Canadian capitals and big cities; and
/// Australian capitals and big cities.
enum AddressPlaces {
    /// The US states, DC and the territories, by postal code.
    static let states: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
        "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
        "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
        "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas",
        "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming", "DC": "D C", "PR": "Puerto Rico", "GU": "Guam",
        "VI": "U S Virgin Islands", "AS": "American Samoa", "MP": "Northern Mariana Islands",
    ]

    /// Codes that are also English words or common letters ("OR", "IN", "ME", "OK", "CA" for a
    /// certificate authority): with no ZIP after them they need a place word before the city,
    /// a verb after the code, "-based" or a closing bracket as well as a listed place.
    static let wordLikeStates: Set<String> = [
        "AL", "AR", "CA", "CO", "DE", "GA", "HI", "ID", "IL", "IN", "IA", "LA", "MA", "MD", "ME", "MI", "MO", "MS",
        "MT", "NE", "OH", "OK", "OR", "PA", "UT", "VA", "WA", "WI",
    ]

    /// Territories: read only before a ZIP, or for a listed place after a place word.
    static let territories: Set<String> = ["PR", "GU", "VI", "AS", "MP"]

    /// AP-style state abbreviations ("Salem, Ore.", "Albany, N.Y.").
    static let apStates: [String: String] = [
        "Ala.": "Alabama", "Ariz.": "Arizona", "Ark.": "Arkansas", "Calif.": "California", "Colo.": "Colorado",
        "Conn.": "Connecticut", "Del.": "Delaware", "Fla.": "Florida", "Ga.": "Georgia", "Ill.": "Illinois",
        "Ind.": "Indiana", "Kan.": "Kansas", "Kans.": "Kansas", "Ky.": "Kentucky", "La.": "Louisiana",
        "Md.": "Maryland", "Mass.": "Massachusetts", "Mich.": "Michigan", "Minn.": "Minnesota",
        "Miss.": "Mississippi", "Mo.": "Missouri", "Mont.": "Montana", "Neb.": "Nebraska", "Nebr.": "Nebraska",
        "Nev.": "Nevada", "N.H.": "New Hampshire", "N.J.": "New Jersey", "N.M.": "New Mexico", "N.Y.": "New York",
        "N.C.": "North Carolina", "N.D.": "North Dakota", "Okla.": "Oklahoma", "Ore.": "Oregon",
        "Pa.": "Pennsylvania", "R.I.": "Rhode Island", "S.C.": "South Carolina", "S.D.": "South Dakota",
        "Tenn.": "Tennessee", "Vt.": "Vermont", "Va.": "Virginia", "Wash.": "Washington",
        "W.Va.": "West Virginia", "Wis.": "Wisconsin", "Wyo.": "Wyoming",
    ]

    /// AP abbreviations that are also words or names ("Morning, Miss.", "Goodnight, Pa.",
    /// "Love, Mo."): read only for a listed place or before a ZIP.
    static let wordLikeAPStates: Set<String> = [
        "Miss.", "Pa.", "Mo.", "Ill.", "Ind.", "Mass.", "Wash.", "Del.", "La.", "Ga.", "Va.", "Conn.", "Mich.",
        "Ala.", "Md.",
    ]

    /// Canadian provinces and territories. "BC" stays letters, as it is said; "NL" is
    /// Newfoundland, the everyday name.
    static let provinces: [String: String] = [
        "ON": "Ontario", "QC": "Quebec", "AB": "Alberta", "MB": "Manitoba", "SK": "Saskatchewan",
        "NS": "Nova Scotia", "NB": "New Brunswick", "PE": "Prince Edward Island", "NL": "Newfoundland",
        "YT": "Yukon", "NU": "Nunavut", "NT": "Northwest Territories", "BC": "B C",
    ]

    /// Australian states said by name.
    static let australianStates: [String: String] = [
        "NSW": "New South Wales", "VIC": "Victoria", "QLD": "Queensland", "TAS": "Tasmania",
    ]
    /// Australian states and territories said as letters.
    static let australianLetterStates: Set<String> = ["ACT", "NT", "SA", "WA"]

    /// Whether `place` (the run of capitalised words before the comma) is a listed US place in
    /// the state `code`.
    static func isUSPlace(_ place: String, _ code: String) -> Bool {
        usPlaces.contains(key(place) + "|" + code)
    }

    static func isCanadianPlace(_ place: String) -> Bool { canadianPlaces.contains(key(place)) }

    static func isAustralianPlace(_ place: String) -> Bool { australianPlaces.contains(key(place)) }

    /// A place name as the lists hold it: lower case, no full stops, and "St."/"Saint",
    /// "Ft."/"Fort" and "Mt."/"Mount" folded together ("St. Paul" is "Saint Paul").
    static func key(_ place: String) -> String {
        place.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { word in prefixes[String(word)] ?? String(word) }
            .joined(separator: " ")
    }

    private static let prefixes = ["st": "saint", "ste": "sainte", "ft": "fort", "mt": "mount", "pt": "point"]

    private static let usPlaces: Set<String> = {
        var set = Set<String>()
        for (code, names) in usPlacesByState {
            for name in names.split(separator: ",") {
                set.insert(key(name.trimmingCharacters(in: .whitespaces)) + "|" + code)
            }
        }
        return set
    }()

    private static let usPlacesByState: [String: String] = [
        "AL": "Birmingham, Montgomery, Huntsville, Mobile, Tuscaloosa, Hoover, Auburn, Dothan",
        "AK": "Anchorage, Juneau, Fairbanks",
        "AZ": "Phoenix, Tucson, Mesa, Chandler, Gilbert, Glendale, Scottsdale, Peoria, Tempe, Surprise, Goodyear, Yuma, Flagstaff, Buckeye",
        "AR": "Little Rock, Fort Smith, Fayetteville, Springdale, Jonesboro, Rogers, Conway, Bentonville",
        "CA": "Los Angeles, San Diego, San Jose, San Francisco, Fresno, Sacramento, Long Beach, Oakland, Bakersfield, Anaheim, Santa Ana, Riverside, Stockton, Irvine, Chula Vista, Fremont, San Bernardino, Modesto, Fontana, Oxnard, Moreno Valley, Huntington Beach, Glendale, Santa Clarita, Oceanside, Garden Grove, Rancho Cucamonga, Santa Rosa, Elk Grove, Corona, Lancaster, Palmdale, Hayward, Salinas, Pomona, Sunnyvale, Escondido, Torrance, Pasadena, Orange, Fullerton, Roseville, Visalia, Thousand Oaks, Concord, Simi Valley, Santa Clara, Victorville, Vallejo, Berkeley, El Monte, Downey, Costa Mesa, Inglewood, Carlsbad, Ventura, Fairfield, West Covina, Murrieta, Richmond, Norwalk, Antioch, Temecula, Burbank, Daly City, Rialto, Santa Maria, El Cajon, San Mateo, Clovis, Compton, Vista, South Gate, Mission Viejo, Vacaville, Carson, Hesperia, Santa Monica, Westminster, Redding, Santa Barbara, Chico, Newport Beach, San Leandro, Whittier, Hawthorne, Citrus Heights, Tracy, Alhambra, Livermore, Menifee, Merced, Chino, Indio, Redwood City, Napa, Mountain View, Palo Alto, Cupertino, Beverly Hills, Malibu, Palm Springs, San Luis Obispo, Santa Cruz, Monterey, Davis, Walnut Creek, Pleasanton",
        "CO": "Denver, Colorado Springs, Aurora, Fort Collins, Lakewood, Thornton, Arvada, Westminster, Pueblo, Centennial, Boulder, Greeley, Longmont, Loveland, Broomfield, Grand Junction, Aspen",
        "CT": "Bridgeport, New Haven, Stamford, Hartford, Waterbury, Norwalk, Danbury, New Britain, Greenwich",
        "DE": "Wilmington, Dover, Newark",
        "DC": "Washington",
        "FL": "Jacksonville, Miami, Tampa, Orlando, St. Petersburg, Hialeah, Port St. Lucie, Tallahassee, Cape Coral, Fort Lauderdale, Pembroke Pines, Hollywood, Gainesville, Miramar, Coral Springs, Palm Bay, West Palm Beach, Clearwater, Lakeland, Pompano Beach, Miami Gardens, Davie, Boca Raton, Sunrise, Deltona, Plantation, Palm Coast, Fort Myers, Miami Beach, Melbourne, Kissimmee, Daytona Beach, Ocala, Sarasota, Naples, Key West, Pensacola, Coral Gables, St. Augustine, Panama City",
        "GA": "Atlanta, Columbus, Augusta, Macon, Savannah, Athens, Sandy Springs, Roswell, Johns Creek, Warner Robins, Albany, Alpharetta, Marietta",
        "HI": "Honolulu, Hilo, Kailua",
        "ID": "Boise, Meridian, Nampa, Idaho Falls, Pocatello, Coeur d'Alene, Twin Falls",
        "IL": "Chicago, Aurora, Joliet, Naperville, Rockford, Springfield, Elgin, Peoria, Champaign, Waukegan, Cicero, Bloomington, Evanston, Schaumburg, Decatur, Skokie, Oak Park, Urbana, Normal",
        "IN": "Indianapolis, Fort Wayne, Evansville, South Bend, Carmel, Fishers, Bloomington, Hammond, Gary, Lafayette, Muncie, Terre Haute, West Lafayette",
        "IA": "Des Moines, Cedar Rapids, Davenport, Sioux City, Iowa City, Waterloo, Ames, West Des Moines, Council Bluffs, Dubuque",
        "KS": "Wichita, Overland Park, Kansas City, Olathe, Topeka, Lawrence, Manhattan, Salina",
        "KY": "Louisville, Lexington, Bowling Green, Owensboro, Covington, Frankfort",
        "LA": "New Orleans, Baton Rouge, Shreveport, Lafayette, Lake Charles, Metairie, Kenner, Monroe",
        "ME": "Portland, Augusta, Bangor, Lewiston, Bar Harbor",
        "MD": "Baltimore, Annapolis, Frederick, Rockville, Gaithersburg, Columbia, Silver Spring, Bethesda, Ocean City",
        "MA": "Boston, Worcester, Springfield, Cambridge, Lowell, Brockton, New Bedford, Quincy, Lynn, Fall River, Newton, Somerville, Salem, Plymouth, Amherst, Nantucket",
        "MI": "Detroit, Grand Rapids, Warren, Sterling Heights, Ann Arbor, Lansing, Flint, Dearborn, Livonia, Troy, Kalamazoo, East Lansing, Traverse City",
        "MN": "Minneapolis, St. Paul, Rochester, Duluth, Bloomington, Brooklyn Park, Plymouth, St. Cloud, Eagan, Edina, Mankato",
        "MS": "Jackson, Gulfport, Southaven, Biloxi, Hattiesburg, Tupelo, Oxford",
        "MO": "Kansas City, St. Louis, Springfield, Columbia, Independence, Lee's Summit, St. Joseph, St. Charles, Joplin, Jefferson City, Branson",
        "MT": "Billings, Missoula, Great Falls, Bozeman, Butte, Helena",
        "NE": "Omaha, Lincoln, Bellevue, Grand Island, Kearney",
        "NV": "Las Vegas, Henderson, Reno, North Las Vegas, Sparks, Carson City",
        "NH": "Manchester, Nashua, Concord, Portsmouth, Hanover",
        "NJ": "Newark, Jersey City, Paterson, Elizabeth, Lakewood, Edison, Woodbridge, Toms River, Trenton, Clifton, Camden, Cherry Hill, Hoboken, Princeton, Atlantic City, New Brunswick",
        "NM": "Albuquerque, Las Cruces, Rio Rancho, Santa Fe, Roswell, Taos",
        "NY": "New York, New York City, Buffalo, Rochester, Yonkers, Syracuse, Albany, New Rochelle, Schenectady, Utica, White Plains, Ithaca, Binghamton, Brooklyn, Queens, Bronx, Staten Island, Manhattan, Saratoga Springs, Poughkeepsie",
        "NC": "Charlotte, Raleigh, Greensboro, Durham, Winston-Salem, Fayetteville, Cary, Wilmington, High Point, Asheville, Greenville, Chapel Hill",
        "ND": "Fargo, Bismarck, Grand Forks, Minot",
        "OH": "Columbus, Cleveland, Cincinnati, Toledo, Akron, Dayton, Parma, Canton, Youngstown, Lorain, Springfield, Athens, Oxford, Sandusky",
        "OK": "Oklahoma City, Tulsa, Norman, Broken Arrow, Edmond, Lawton, Stillwater",
        "OR": "Portland, Salem, Eugene, Gresham, Hillsboro, Beaverton, Bend, Medford, Springfield, Corvallis, Ashland",
        "PA": "Philadelphia, Pittsburgh, Allentown, Reading, Erie, Scranton, Bethlehem, Lancaster, Harrisburg, State College, Hershey, Gettysburg",
        "RI": "Providence, Warwick, Cranston, Pawtucket, Newport",
        "SC": "Charleston, Columbia, North Charleston, Mount Pleasant, Rock Hill, Greenville, Spartanburg, Myrtle Beach, Hilton Head Island",
        "SD": "Sioux Falls, Rapid City, Pierre",
        "TN": "Nashville, Memphis, Knoxville, Chattanooga, Clarksville, Murfreesboro, Franklin, Jackson, Johnson City, Gatlinburg",
        "TX": "Houston, San Antonio, Dallas, Austin, Fort Worth, El Paso, Arlington, Corpus Christi, Plano, Laredo, Lubbock, Irving, Garland, Frisco, McKinney, Amarillo, Grand Prairie, Brownsville, Killeen, Pasadena, Mesquite, McAllen, Denton, Waco, Carrollton, Midland, Abilene, Odessa, Beaumont, Round Rock, Richardson, Pearland, College Station, Wichita Falls, Lewisville, Tyler, San Angelo, League City, Allen, Sugar Land, Edinburg, Galveston, San Marcos",
        "UT": "Salt Lake City, West Valley City, West Jordan, Provo, Orem, Sandy, St. George, Ogden, Layton, Lehi, Logan, Park City, Moab",
        "VT": "Burlington, Montpelier",
        "VA": "Virginia Beach, Chesapeake, Norfolk, Arlington, Richmond, Newport News, Alexandria, Hampton, Roanoke, Portsmouth, Suffolk, Lynchburg, Charlottesville, Williamsburg",
        "WA": "Seattle, Spokane, Tacoma, Vancouver, Bellevue, Kent, Everett, Renton, Spokane Valley, Federal Way, Yakima, Kirkland, Bellingham, Redmond, Olympia",
        "WV": "Charleston, Huntington, Morgantown, Wheeling",
        "WI": "Milwaukee, Madison, Green Bay, Kenosha, Racine, Appleton, Waukesha, Eau Claire, Oshkosh",
        "WY": "Cheyenne, Casper, Laramie, Jackson",
        "PR": "San Juan, Bayamón, Carolina, Ponce, Caguas",
        "GU": "Hagåtña, Dededo, Tamuning",
        "VI": "Charlotte Amalie, Christiansted",
        "AS": "Pago Pago",
        "MP": "Saipan",
    ]

    private static let canadianPlaces: Set<String> = Set("""
        Toronto, Montreal, Montréal, Vancouver, Calgary, Edmonton, Ottawa, Winnipeg, Quebec City, Québec, Hamilton, \
        Kitchener, London, Victoria, Halifax, Oshawa, Windsor, Saskatoon, Regina, St. Catharines, Barrie, Kelowna, \
        Abbotsford, Sherbrooke, Guelph, Kingston, Moncton, Saint John, Fredericton, Charlottetown, St. John's, \
        Whitehorse, Yellowknife, Iqaluit, Thunder Bay, Sudbury, Mississauga, Brampton, Surrey, Laval, Markham, \
        Vaughan, Gatineau, Longueuil, Burnaby, Richmond, Oakville, Burlington, Lethbridge, Red Deer, Nanaimo, \
        Kamloops, Saguenay, Trois-Rivières, Lévis, Brantford, Peterborough, Sault Ste. Marie, Waterloo, Cambridge, \
        Niagara Falls, Prince George, Medicine Hat, Brandon, Dartmouth, Corner Brook, Summerside
        """.split(separator: ",").map { key($0.trimmingCharacters(in: .whitespacesAndNewlines)) })

    private static let australianPlaces: Set<String> = Set("""
        Sydney, Melbourne, Brisbane, Perth, Adelaide, Hobart, Darwin, Canberra, Gold Coast, Newcastle, Wollongong, \
        Geelong, Townsville, Cairns, Toowoomba, Ballarat, Bendigo, Launceston, Albury, Mackay, Fremantle, \
        Parramatta, Alice Springs
        """.split(separator: ",").map { key($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
}
