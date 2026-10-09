/// A chat as the local reader sees it.
struct LocalChat: Equatable {
    enum Kind: String {
        case privateChat = "private"
        case basicGroup = "basic_group"
        case supergroup
        case channel
        case secret
        case unknown
    }

    let id: Int64
    let title: String?
    let type: Kind
}
