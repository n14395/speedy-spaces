// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// A self-contained SF Symbol picker: a search field over a scrollable grid of symbols.
/// Selecting a symbol invokes `onPick`. Also exposes the current selection so the host
/// can keep a text field in sync (and vice-versa).
final class SFSymbolPicker: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {

    var onPick: ((String) -> Void)?

    private let searchField = NSSearchField()
    private let categoryPopup = NSPopUpButton()
    private let collectionView = NSCollectionView()
    private var results: [String] = SFSymbolCatalog.all
    private var selectedName: String?

    private var selectedCategory: String { categoryPopup.titleOfSelectedItem ?? SFSymbolCatalog.allCategory }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func build() {
        searchField.placeholderString = "Search symbols…"
        searchField.delegate = self

        categoryPopup.addItems(withTitles: SFSymbolCatalog.categoryNames)
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged)
        categoryPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 38, height: 38)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.register(SymbolItem.self, forItemWithIdentifier: SymbolItem.id)
        collectionView.backgroundColors = [.clear]

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder

        let searchRow = NSStackView(views: [searchField, categoryPopup])
        searchRow.orientation = .horizontal
        searchRow.spacing = 6
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [searchRow, scroll])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Sync the grid selection/scroll to an externally-set symbol name.
    func setSelected(_ name: String?) {
        selectedName = name
        collectionView.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    @objc private func categoryChanged() { applyFilter() }

    private func applyFilter() {
        results = SFSymbolCatalog.search(searchField.stringValue, category: selectedCategory)
        collectionView.reloadData()
    }

    // MARK: Data source

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        results.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: SymbolItem.id, for: indexPath) as! SymbolItem
        let name = results[indexPath.item]
        item.configure(symbolName: name, selected: name == selectedName)
        return item
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first else { return }
        let name = results[ip.item]
        selectedName = name
        onPick?(name)
        cv.reloadData()
    }
}

/// One symbol cell.
private final class SymbolItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("SymbolItem")
    private let symbolView = NSImageView()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .labelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 22),
            symbolView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    func configure(symbolName: String, selected: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName)?
            .withSymbolConfiguration(config)
        view.toolTip = symbolName
        view.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
    }
}
