import SwiftUI
import AppKit

/// Replaces `LicenseView` (removed in 0.10.0 — subscription/keys dropped, the
/// app is free and never touches the network). Same footer slot, same visual
/// language as `AboutView`/the old license window: a short "why free" note
/// plus a card of outbound links to the author's portfolio, storefront and
/// Telegram.
struct AuthorLinksView: View {
    @Environment(\.appTheme) private var theme

    /// Exposed so `AuthorLinksViewTests` can assert every URL/handle is
    /// present without duplicating the literals in the test file.
    static let links: [(icon: String, title: String, subtitle: String, url: String)] = [
        (
            "person.text.rectangle", "Портфолио: просто",
            "Понятным языком: что могу сделать для вас",
            "https://shulgin.is-a.dev/store/prosto/"
        ),
        (
            "chevron.left.forwardslash.chevron.right", "Портфолио: профи",
            "Для технической аудитории: код, проекты, пруфы",
            "https://shulgin.is-a.dev/"
        ),
        (
            "bag", "Витрина",
            "Приложения, готовый код и услуги",
            "https://shulgin.is-a.dev/store/"
        ),
        (
            "paperplane", "Написать в Telegram",
            "@Aleksandr_NFA — вопросы, идеи, заказы",
            "https://t.me/Aleksandr_NFA"
        ),
    ]

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .frame(width: 400, height: 360)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Qwerty Switcher — бесплатно")
                    .font(.appText(22, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(
                    "Без подписки, ключей и облака. Сделал Александр Шульгин — "
                        + "@Aleksandr_NFA, GitHub Sanexxxx777. Если приложение "
                        + "пригодилось — загляните:"
                )
                .font(.appText(11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(Self.links.enumerated()), id: \.offset) { index, link in
                    AuthorLinkRow(
                        icon: link.icon, title: link.title, subtitle: link.subtitle, url: link.url
                    )
                    if index < Self.links.count - 1 {
                        Rectangle().fill(theme.border).frame(height: 1)
                    }
                }
            }
            .settingsCard()

            Text("Ввод обрабатывается локально и никогда не покидает Mac.")
                .font(.appText(10))
                .foregroundStyle(theme.textMuted)
        }
        .padding(Space.xl)
    }
}

private struct AuthorLinkRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let subtitle: String
    let url: String
    @State private var isHovered = false

    var body: some View {
        Button {
            guard let target = URL(string: url) else { return }
            NSWorkspace.shared.open(target)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title)
                        .font(.appText(13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(.appText(11))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(isHovered ? theme.bgInput : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
