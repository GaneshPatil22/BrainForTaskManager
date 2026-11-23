import Foundation

/// What kind of work a task is. Orthogonal to `ItemType` (task/idea/note/...),
/// which says what the capture *is*; this says what doing it *involves*.
///
/// The taxonomy came out of the generated datasets, where five selection
/// policies turned out to pivot on it (`docs/13-generated-datasets.md`).
public enum TaskCategory: String, Sendable, Codable, CaseIterable {
    case paperwork  // forms, documents, admin
    case errands  // shopping, pickups, drop-offs
    case communication  // calls, messages, replies
    case planning  // booking, scheduling, deciding
    case deepWork  // writing, designing, building
    case chores  // cleaning, cooking, repairs, upkeep
    case money  // bills, payments, accounts
    case learning  // reading, studying, practice
    case health  // exercise, medical, rest

    /// How it reads in an explanation ("Errands and shopping batch").
    public var displayName: String {
        switch self {
        case .paperwork: "paperwork and admin"
        case .errands: "errands and shopping"
        case .communication: "calls and messages"
        case .planning: "planning and booking"
        case .deepWork: "creative or deep work"
        case .chores: "hands-on chores and upkeep"
        case .money: "money and payments"
        case .learning: "study or learning"
        case .health: "health and self-care"
        }
    }
}

/// Assigns a category from the task title, deterministically.
///
/// **T0 — a keyword lexicon, not a model call** (`docs/09-tiering.md`).
/// Category is overwhelmingly determined by the leading verb: *call* → talking
/// to someone, *buy* → an errand, *pay* → money. That is a grammar, not a
/// judgement, so it belongs in code.
///
/// Measured accuracy is recorded in the AI Justification Test entry in
/// `DECISIONS.md`. Abstention is always available and always preferred over a
/// coin-flip guess.
public enum CategoryClassifier {

    /// **Strong** terms: decisive on their own. Mostly objects, plus verbs that
    /// only ever mean one thing ("pay", "call").
    ///
    /// The split exists because the leading verb alone is not enough. In the
    /// labelled data `collect` leads 33 paperwork titles *and* 11 money ones;
    /// `book` leads both planning and health. The object disambiguates — "book
    /// flights" vs "book a doctor" — so objects carry the weight.
    static let strong: [TaskCategory: [String]] = [
        .health: [
            "doctor", "dentist", "clinic", "hospital", "physio", "physiotherapy",
            "medicine", "medicines", "tablets", "vitamins", "blood test", "eye test",
            "checkup", "check-up", "vaccination", "vaccine", "therapy", "dental",
            "gym", "workout", "exercise", "yoga", "jog", "swim", "stretch", "steps",
            "meditation", "meditate", "nap", "diet", "walk", "rest",
            "dawai", "kasrat", "sehat",
        ],
        .deepWork: [
            "deck", "slides", "presentation", "draft", "logo", "website", "mockup",
            "wireframe", "portfolio", "blog", "article", "newsletter", "script",
            "storyboard", "prototype", "reel", "video", "shoot", "sketch", "painting",
            "composition", "write", "compose", "design", "illustrate", "draw",
            "rehearsal", "rehearse", "outline", "photograph", "stitch",
        ],
        .paperwork: [
            "certificate", "marksheet", "transcript", "document", "documents", "form",
            "forms", "licence", "license", "passport", "aadhaar", "aadhar", "pan card",
            "kyc", "visa", "policy", "statement", "records", "portal", "challan",
            "affidavit", "noc", "bonafide", "declaration", "attendance", "paperwork",
            "submit", "renew", "register", "registration", "apply", "application",
            "kagaz", "darkhaast",
        ],
        .chores: [
            "bedsheet", "bedsheets", "bedding", "curtains", "laundry", "dishes",
            "utensils", "kitchen", "bathroom", "fridge", "oven", "filter", "bulb",
            "tap", "plants", "garden", "dustbin", "cupboard", "almirah", "shelf",
            "tiffin", "pantry", "clean", "wash", "tidy", "declutter", "fold", "iron",
            "sweep", "mop", "dust", "vacuum", "cook", "chop", "laundry",
            "saaf", "dhona", "jhadu", "pocha", "nashta",
        ],
        .errands: [
            "groceries", "grocery", "vegetables", "sabzi", "milk", "atta", "dal",
            "paneer", "gifts", "stationery", "cylinder", "buy", "purchase", "restock",
            "refill", "courier", "market", "shopping",
            "kharidna", "mangwana", "bazaar", "dukaan", "mandi", "thela",
        ],
        .money: [
            "bill", "bills", "emi", "kisht", "premium", "invoice", "tax", "gst",
            "salary", "rent", "loan", "insurance", "recharge", "subscription", "fee",
            "fees", "upi", "refund", "reimburse", "reimbursement", "pay", "settle",
            "reconcile", "savings", "budget",
            "paisa", "paise", "hisaab", "udhaari", "wasool", "bhugtan",
        ],
        .communication: [
            "call", "phone", "whatsapp", "email", "message", "msg", "reply", "respond",
            "forward", "inform", "notify", "thank", "invite", "congratulate",
            "apologise", "apologize", "ping", "follow up", "followup",
            "baat", "bulana", "bolna", "poochna", "bhejna", "sandesh",
        ],
        .learning: [
            "chapter", "syllabus", "lecture", "course", "exam", "assignment",
            "homework", "quiz", "flashcards", "tutorial", "revise", "revision",
            "study", "learn", "read",
            "padhai", "padhna", "seekhna", "riyaz",
        ],
        .planning: [
            "itinerary", "tickets", "ticket", "flights", "flight", "hotel", "cab",
            "venue", "menu", "meals", "calendar", "booking", "book", "reserve",
            "schedule", "shortlist", "plan", "planning", "planned", "arrange",
            "tay karna", "plan karna",
        ],
    ]

    /// **Weak** terms: ambiguous verbs that nudge rather than decide. "check",
    /// "collect", "update" lead titles in three different categories each.
    static let weak: [TaskCategory: [String]] = [
        .paperwork: [
            "collect", "check", "update", "download", "upload", "scan",
            "verify", "sign", "file", "log", "track",
        ],
        .communication: [
            "confirm", "send", "ask", "tell", "share", "post", "meet",
            "remind", "wish", "greet", "chat",
        ],
        .deepWork: [
            "finish", "prepare", "review", "make", "start", "test", "edit",
            "build", "code", "develop", "create", "record", "brainstorm",
        ],
        .chores: [
            "pack", "unpack", "clear", "charge", "water", "prep", "sort",
            "label", "repair", "fix", "replace", "assemble", "install",
            "dispose", "keep",
        ],
        .planning: [
            "plan", "arrange", "compare", "choose", "decide", "pick",
            "slot", "appointment", "find",
        ],
        .money: ["deposit", "withdraw", "transfer", "open"],
        .errands: [
            "order", "print", "photocopy", "xerox", "deliver", "donate",
            "exchange", "pickup", "lana",
        ],
        .learning: ["practice", "practise", "solve", "notes", "watch", "paper"],
        .health: ["refill", "take", "do"],
    ]

    /// A leading match counts for more than one buried mid-title, and a strong
    /// term counts for more than a weak one.
    ///
    /// These four numbers were swept against the 1,308 labelled titles, not
    /// chosen by feel. Worth recording: the intuition that the *object* should
    /// outweigh the *verb* ("book a dentist" vs "book a flight") is **wrong on
    /// aggregate** — inverting them drops overall accuracy from 67.0% to 64.8%.
    /// The leading verb really is the more informative signal, and the dentist
    /// case is a known, measured cost of that.
    static let strongLeading = 4.0
    static let strongBody = 3.0
    static let weakLeading = 1.5
    static let weakBody = 0.5

    /// Minimum margin the winner must beat the runner-up by, as a fraction of
    /// the winner's score. Chosen from the measured coverage/accuracy curve
    /// (`brain category-eval --sweep`), not picked by feel.
    /// 0.25 is the largest margin that costs no accuracy on the labelled set
    /// (measured: coverage 83.6%, accuracy-on-attempted 80.1% — identical to
    /// margin 0). Raising it further trades away more right answers than wrong
    /// ones. The knob is kept because it will matter as the lexicon improves;
    /// today the limiting factor is lexicon quality, not the threshold.
    public static let defaultMinMargin = 0.25

    /// Returns the category, or abstains. Never guesses between a tie.
    ///
    /// Abstention is preferred over a wrong answer: an abstained field escalates
    /// to a later tier or to the user, whereas a confidently wrong one is
    /// silently wrong (`docs/04-scorecard.md`).
    public static func classify(
        _ title: String, minMargin: Double = defaultMinMargin
    ) -> Classified<TaskCategory> {
        let lower = title.lowercased()
        let tokenList = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = tokenList.first else { return .unknown() }
        // A Set, not an Array: this is probed once per lexicon term (~400 of
        // them), and `Array.contains` made a 60k-character capture take 230ms.
        let tokens = Set(tokenList)

        var scores: [TaskCategory: Double] = [:]
        func accumulate(_ table: [TaskCategory: [String]], leading: Double, body: Double) {
            for (category, terms) in table {
                for term in terms {
                    if term.contains(" ") {
                        // Multi-word terms match as a phrase anywhere in the title.
                        if lower.contains(term) { scores[category, default: 0] += leading }
                    } else if first == term {
                        scores[category, default: 0] += leading
                    } else if tokens.contains(term) {
                        scores[category, default: 0] += body
                    }
                }
            }
        }
        accumulate(strong, leading: strongLeading, body: strongBody)
        accumulate(weak, leading: weakLeading, body: weakBody)

        guard
            let best = scores.max(by: { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
            })
        else { return .unknown() }

        // A tie between two categories is a genuine ambiguity, not something to
        // break arbitrarily — abstain and let a later tier or the user decide.
        let tied = scores.filter { $0.value == best.value }
        guard tied.count == 1 else { return .unknown() }

        // Confidence rises with how decisively the best beat the rest.
        let runnerUp = scores.filter { $0.key != best.key }.map(\.value).max() ?? 0
        let margin = (best.value - runnerUp) / best.value
        guard margin >= minMargin else { return .unknown() }
        let confidence = min(0.95, 0.55 + 0.4 * margin)
        return Classified(best.key, confidence: confidence, tier: .t0)
    }
}
