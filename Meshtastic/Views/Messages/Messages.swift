//
//  Messages.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 8/29/23.
//

import SwiftUI
import SwiftData
import OSLog
import TipKit

struct Messages: View {

	@Environment(\.modelContext) private var context
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@ObservedObject	var router: Router
	@Binding var unreadChannelMessages: Int
	@Binding var unreadDirectMessages: Int
	/// Store the connected node's `num`, NOT the `NodeInfoEntity` itself, and resolve the object
	/// from the live context every render (see `node`). Caching the SwiftData model here traps
	/// ("destroyed by ModelContext.reset") when the container is recreated (data clear / node
	/// switch) while this view still reads `node?.myInfo`; a fresh fetch returns nil safely.
	@State private var nodeNum: Int64?
	@State private var userSelection: UserEntity? // Nothing selected by default.
	@State private var channelSelection: ChannelEntity? // Nothing selected by default.

	@State private var columnVisibility = NavigationSplitViewVisibility.all
	/// What the single stack shows on a phone at regular width. See `prefersStackOverOverlaySidebar`.
	@State private var stackPath = NavigationPath()
	/// The last path the stack was given from the selection, so a change made here is not
	/// mistaken for the person going back.
	@State private var syncedStackPath = NavigationPath()

	/// Resolves the connected node from the current context on each access. Never cached, so it
	/// can't outlive a container recreation. `getNodeInfo` is a `try?` fetch and returns nil if
	/// the store is mid-reset.
	private var node: NodeInfoEntity? {
		guard let nodeNum else { return nil }
		return getNodeInfo(id: nodeNum, context: context)
	}

	/// Binding handed to ChannelList/UserList. The getter resolves `node` from the live context on
	/// every read (never a captured/cached object), so the retained closure can't read a reset
	/// NodeInfoEntity if a container recreation happens before this view re-renders.
	private var nodeBinding: Binding<NodeInfoEntity?> {
		Binding(get: { self.node }, set: { self.nodeNum = $0?.num })
	}

	/// Sidebar selection binding. Reads/writes the durable, payload-free `router.messagesSection`,
	/// so the bound value always matches a `.channels()` / `.directMessages()` row and the
	/// collapsed `NavigationSplitView` back stack stays intact. The setter only fires on a user tap
	/// (selecting a different section), where we also reset the detail pane so the new section
	/// starts with nothing selected — matching the behavior of a fresh sidebar navigation — and
	/// hide the sidebar so the channel or contact list is what's on screen.
	private var sidebarSelection: Binding<MessagesNavigationState?> {
		Binding(
			get: { self.router.messagesSection },
			set: { newValue in
				self.router.messagesSection = newValue
				self.channelSelection = nil
				self.userSelection = nil
				if newValue != nil {
					self.columnVisibility = .doubleColumn
				}
			}
		)
	}

	/// The open iPhone Duo display is regular width but only about 669pt across. That is
	/// not enough for three columns, so `NavigationSplitView` draws the sidebar and the
	/// channel or contact list as overlays on top of the conversation, and with
	/// `columnVisibility` forced to `.all` they cover its navigation bar — taking the back
	/// button of a node pushed from a message with them. This is the layout the node list
	/// had before it moved to a stack in the same case.
	///
	/// A phone-idiom device never has room for the columns, so at this width it gets the
	/// same single stack it gets folded. Compact width still goes through the split view,
	/// which collapses to a stack on its own and is the path every iPhone already takes.
	/// iPad and Mac are untouched.
	private var prefersStackOverOverlaySidebar: Bool {
		horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .phone
	}

	/// The stack the current selection stands for: the section, then the open conversation.
	///
	/// The section and the selected channel or contact stay the source of truth in both
	/// layouts, so deep links, notification taps and `popToRoot` move the stack exactly as
	/// they move the split view, and opening or closing the device keeps the conversation.
	///
	/// Only the conversation that belongs to the section counts. `route(url:)` moves the
	/// section before this view consumes the link, and for that moment the other section's
	/// conversation is still selected; pushing it would open the wrong thread.
	private var selectionPath: NavigationPath {
		var path = NavigationPath()
		guard let section = router.messagesSection else { return path }
		path.append(section)
		switch section {
		case .channels:
			if let channelSelection {
				path.append(channelSelection)
			}
		case .directMessages:
			if let userSelection {
				path.append(userSelection)
			}
		}
		return path
	}

	var body: some View {
		Group {
			if prefersStackOverOverlaySidebar {
				messagesStack
			} else {
				messagesSplitView
			}
		}
		.onAppear {
			// Handles the deep link set by `route(url:)` before this view began observing.
			consumeDeepLink(router.messagesState)
			revealSidebarForEmptySelection()
		}.onChange(of: router.messagesState) { _, newValue in
			consumeDeepLink(newValue)
		}.onChange(of: router.messagesSection) { _, newValue in
			// A reset (e.g. `popToRoot` on disconnect) nils the section; clear the detail pane to
			// match. Section *changes* between .channels/.directMessages are reset by the sidebar
			// setter and by `consumeDeepLink`, so only the nil case needs handling here.
			if newValue == nil {
				channelSelection = nil
				userSelection = nil
				revealSidebarForEmptySelection()
			}
		}.onChange(of: prefersStackOverOverlaySidebar) { _, prefersStack in
			// Start the next stack from the selection, not from whatever it held when the
			// device last closed. The stack's own handlers are gone by now, so this clears
			// nothing else.
			if !prefersStack {
				stackPath = NavigationPath()
				syncedStackPath = NavigationPath()
			}
		}
	}

	// MARK: - Stack

	private var messagesStack: some View {
		NavigationStack(path: $stackPath) {
			sidebar
				// The rows here and in the channel and contact lists are `NavigationLink(value:)`,
				// which the split view turns into a selection. In a stack they push, so each value
				// needs a destination, and each destination reports the selection it opened.
				.navigationDestination(for: MessagesNavigationState.self) { section in
					sectionList(section)
						.onAppear {
							guard router.messagesSection != section else { return }
							router.messagesSection = section
							channelSelection = nil
							userSelection = nil
						}
				}
				.navigationDestination(for: ChannelEntity.self) { channel in
					Group {
						if let myInfo = node?.myInfo {
							ChannelMessageList(myInfo: myInfo, channel: channel)
								.trackScreen(.channelMessages)
						}
					}
					.onAppear {
						channelSelection = channel
						userSelection = nil
					}
				}
				.navigationDestination(for: UserEntity.self) { user in
					UserMessageList(user: user)
						.trackScreen(.directMessages)
						.onAppear {
							userSelection = user
							channelSelection = nil
						}
				}
				.navigationDestination(for: Int64.self) { nodeNum in
					nodeDetail(nodeNum)
				}
		}
		.onAppear {
			// Empty only on the first appearance after the device opens. Any other time it
			// holds what the person navigated to, which a tab switch should not undo.
			guard stackPath.isEmpty else { return }
			var transaction = Transaction()
			transaction.disablesAnimations = true
			withTransaction(transaction) {
				syncStackToSelection(selectionPath)
			}
		}
		.onChange(of: selectionPath) { _, newPath in
			// A deep link, a notification tap or a reset changed the selection.
			syncStackToSelection(newPath)
		}
		.onChange(of: stackPath) { _, path in
			// Back is the one move the destinations above don't report. A path this view
			// set from the selection already matches it.
			guard path != syncedStackPath else { return }
			if path.count < 2 {
				channelSelection = nil
				userSelection = nil
			}
			if path.isEmpty && router.messagesSection != nil {
				router.messagesSection = nil
			}
		}
	}

	private func syncStackToSelection(_ path: NavigationPath) {
		syncedStackPath = path
		if stackPath != path {
			stackPath = path
		}
	}

	// MARK: - Split View

	private var messagesSplitView: some View {
		NavigationSplitView(columnVisibility: $columnVisibility) {
			sidebar
		} content: {
			sectionList(router.messagesSection)
		} detail: {
			NavigationStack {
				Group {
					if let myInfo = node?.myInfo, let channelSelection {
						ChannelMessageList(myInfo: myInfo, channel: channelSelection)
							.trackScreen(.channelMessages)
					} else if let userSelection {
						UserMessageList(user: userSelection)
							.trackScreen(.directMessages)
					} else if case .channels = router.messagesSection {
						Text("Select a channel")
					} else if case .directMessages = router.messagesSection {
						Text("Select a conversation")
					}
				}
				.navigationDestination(for: Int64.self) { nodeNum in
					nodeDetail(nodeNum)
				}
			}
		}
		.navigationSplitViewStyle(.balanced)
	}

	// MARK: - Columns

	private var sidebar: some View {
		List(selection: sidebarSelection) {
			NavigationLink(value: MessagesNavigationState.channels()) {
				Spacer()
				Label {
					Text("Channels")
						.badge(unreadChannelMessages)
						.font(.title2)
						.padding()
				} icon: {
					Image(systemName: "person.2")
						.symbolRenderingMode(.hierarchical)
						.foregroundColor(.accentColor)
						.font(.title2)
						.padding()
				}
			}
			.alignmentGuide(.listRowSeparatorLeading) {
				$0[.leading]
			}
			.accessibilityElement(children: .combine)
			.accessibilityLabel(unreadChannelMessages > 0
				? String(localized: "Channels, \(unreadChannelMessages) unread", comment: "VoiceOver: Channels section with unread message count")
				: String(localized: "Channels", comment: "VoiceOver: Channels section"))
			NavigationLink(value: MessagesNavigationState.directMessages()) {
				Spacer()
				Label {
					Text("Direct Messages")
						.badge(unreadDirectMessages)
						.font(.title2)
						.padding()
				} icon: {
					Image(systemName: "person")
						.symbolRenderingMode(.hierarchical)
						.foregroundColor(.accentColor)
						.font(.title2)
						.padding()
				}
			}
			.alignmentGuide(.listRowSeparatorLeading) {
				$0[.leading]
			}
			.accessibilityElement(children: .combine)
			.accessibilityLabel(unreadDirectMessages > 0
				? String(localized: "Direct Messages, \(unreadDirectMessages) unread", comment: "VoiceOver: Direct Messages section with unread message count")
				: String(localized: "Direct Messages", comment: "VoiceOver: Direct Messages section"))
			Spacer()
			TipView(MessagesTip(), arrowEdge: .top)
				.tipViewStyle(PersistentTipStyle())
				.listRowSeparator(.hidden)
			Spacer()
				.listRowSeparator(.hidden)
		}
		.listStyle(.plain)
		.navigationTitle("Messages")
		.navigationBarTitleDisplayMode(.large)
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				MeshtasticLogo()
			}
		}
	}

	@ViewBuilder
	private func sectionList(_ section: MessagesNavigationState?) -> some View {
		switch section {
		case .channels:
			ChannelList(node: nodeBinding, channelSelection: $channelSelection)
				// Removed navigationTitle and navigationBarTitleDisplayMode here.
				// ChannelList.swift now handles this within its own NavigationStack.
		case .directMessages:
			UserList(node: nodeBinding, userSelection: $userSelection)
				// Removed navigationTitle here. UserList will handle this.
		case nil:
			Text("Select a conversation type")
		}
	}

	@ViewBuilder
	private func nodeDetail(_ nodeNum: Int64) -> some View {
		if let node = getNodeInfo(id: nodeNum, context: context) {
			NodeDetail(node: node, nodeNum: nodeNum)
				.trackScreen(.nodeDetail)
		}
	}

	/// The empty split view otherwise lands on "Select a conversation type" with the
	/// sidebar collapsed, and the only way forward is the sidebar button. Open it
	/// while nothing is selected. A dismissal made after a conversation type is
	/// chosen is left alone — this is not called in that case, and the follow-up
	/// bails if a selection arrived in the meantime.
	private func revealSidebarForEmptySelection() {
		guard router.messagesSection == nil else { return }
		columnVisibility = .all
		// The split view writes its own visibility during the first layout pass and
		// can collapse the sidebar again after the assignment above.
		Task { @MainActor in
			guard router.messagesSection == nil else { return }
			columnVisibility = .all
		}
	}

	private func bootstrapNodeNum() {
		let nodeId = Int64(UserDefaults.preferredPeripheralNum)
		if nodeId > 0 && nodeNum == nil {
			nodeNum = nodeId
		}
	}

	/// Resolves a deep-link `messagesState` into the selected conversation, then clears the payload
	/// so it's consumed exactly once. Clearing `router.messagesState` re-fires the `onChange` above
	/// with `nil`, which this guard turns into a no-op — selections are never clobbered. If the
	/// target can't be resolved yet (e.g. channels not loaded on a cold launch) the payload is left
	/// in place so a later `onAppear` can retry instead of silently dropping the deep link.
	private func consumeDeepLink(_ state: MessagesNavigationState?) {
		bootstrapNodeNum()
		guard let state else { return }

		switch state {
		case .channels(channelId: let channelId, messageId: _):
			router.messagesSection = .channels()
			guard let channelId else {
				channelSelection = nil
				userSelection = nil
				break
			}
			guard let channel = node?.myInfo?.channels.first(where: { $0.id == channelId }) else {
				return // Not resolvable yet — keep the payload and retry on the next appear.
			}
			channelSelection = channel
			// Clear the sibling DM selection so the detail pane (which prioritizes
			// channelSelection) can't surface a stale conversation under the Channels section.
			userSelection = nil
		case .directMessages(userNum: let userNum, messageId: _):
			router.messagesSection = .directMessages()
			if let userNum {
				// getUser always resolves (creating a placeholder if needed), so a DM deep link
				// never needs the cold-launch retry that the channel branch does.
				userSelection = getUser(id: userNum, context: context)
			} else {
				userSelection = nil
			}
			// Clear the sibling channel selection: the detail pane prioritizes channelSelection,
			// so a previously-open channel would otherwise mask this DM and show the wrong thread.
			channelSelection = nil
		}

		router.messagesState = nil // Consumed — prevents a re-appear from re-resolving it.
	}
}
