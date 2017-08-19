import UIKit

open class PagingViewController<T: PagingItem>:
  UIViewController,
  UICollectionViewDataSource,
  UICollectionViewDelegate,
  EMPageViewControllerDataSource,
  EMPageViewControllerDelegate,
  PagingCollectionViewLayoutDelegate,
  PagingStateMachineDelegate where T: Hashable, T: Comparable {
  
  open let options: PagingOptions
  open weak var dataSource: PagingViewControllerDataSource?
  fileprivate var dataStructure: PagingDataStructure<T>
  
  internal var stateMachine: PagingStateMachine<T>? {
    didSet {
      handleStateMachineUpdate()
    }
  }
  
  open weak var delegate: PagingViewControllerDelegate? {
    didSet {
      collectionViewLayout.delegate = self
    }
  }
  
  open lazy var collectionViewLayout: PagingCollectionViewLayout<T> = {
    return PagingCollectionViewLayout(options: self.options, dataStructure: self.dataStructure)
  }()
  
  open lazy var collectionView: UICollectionView = {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: self.collectionViewLayout)
    collectionView.backgroundColor = .white
    collectionView.isScrollEnabled = false
    return collectionView
  }()
  
  open let pageViewController: EMPageViewController = {
    return EMPageViewController(navigationOrientation: .horizontal)
  }()
  
  public init(options: PagingOptions = DefaultPagingOptions()) {
    self.options = options
    self.dataStructure = PagingDataStructure(visibleItems: [])
    super.init(nibName: nil, bundle: nil)
  }

  required public init?(coder: NSCoder) {
    self.options = DefaultPagingOptions()
    self.dataStructure = PagingDataStructure(visibleItems: [])
    super.init(coder: coder)
  }
  
  open override func loadView() {
    view = PagingView(
      pageView: pageViewController.view,
      collectionView: collectionView,
      options: options)
  }
  
  open override func viewDidLoad() {
    super.viewDidLoad()
    
    addChildViewController(pageViewController)
    pageViewController.didMove(toParentViewController: self)
    pageViewController.delegate = self
    pageViewController.dataSource = self
    
    collectionView.delegate = self
    collectionView.dataSource = self
    collectionView.registerReusableCell(options.menuItemClass)
    
    setupGestureRecognizers()
    
    if let state = stateMachine?.state {
      selectViewController(
        state.currentPagingItem,
        direction: .none,
        animated: false)
    }
  }
  
  open func selectPagingItem(_ pagingItem: T, animated: Bool = false) {
    
    if let stateMachine = stateMachine {
      if let indexPath = dataStructure.indexPathForPagingItem(pagingItem) {
        let direction = dataStructure.directionForIndexPath(indexPath, currentPagingItem: pagingItem)
        stateMachine.fire(.select(
          pagingItem: pagingItem,
          direction: direction,
          animated: animated))
      }
    } else {
      let state: PagingState = .selected(pagingItem: pagingItem)
      stateMachine = PagingStateMachine(initialState: state)
      collectionViewLayout.state = state
      
      if isViewLoaded {
        selectViewController(
          state.currentPagingItem,
          direction: .none,
          animated: false)
        
        if view.window != nil {
          reloadItems(around: state.currentPagingItem)
        }
      }
    }
  }
  
  open override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard let state = stateMachine?.state else { return }
    view.layoutIfNeeded()
    reloadItems(around: state.currentPagingItem)
    selectCollectionViewItem(for: state.currentPagingItem)
  }
  
  open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    guard let stateMachine = stateMachine else { return }
    
    coordinator.animate(alongsideTransition: { context in
      stateMachine.fire(.cancelScrolling)
      let pagingItem = stateMachine.state.currentPagingItem
      self.reloadItems(around: pagingItem)
      self.selectCollectionViewItem(for: pagingItem)
    }, completion: nil)
  }
  
  // MARK: Private
  
  fileprivate func setupGestureRecognizers() {
    let recognizerLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeGestureRecognizer))
    recognizerLeft.direction = .left
    
    let recognizerRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeGestureRecognizer))
    recognizerRight.direction = .right
    
    collectionView.addGestureRecognizer(recognizerLeft)
    collectionView.addGestureRecognizer(recognizerRight)
  }
  
  fileprivate dynamic func handleSwipeGestureRecognizer(_ recognizer: UISwipeGestureRecognizer) {
    guard let stateMachine = stateMachine else { return }
    
    let currentPagingItem = stateMachine.state.currentPagingItem
    var upcomingPagingItem: T? = nil
    
    if recognizer.direction.contains(.left) {
      upcomingPagingItem = dataSource?.pagingViewController(self, pagingItemAfterPagingItem: currentPagingItem)
    } else if recognizer.direction.contains(.right) {
      upcomingPagingItem = dataSource?.pagingViewController(self, pagingItemBeforePagingItem: currentPagingItem)
    }
    
    if let item = upcomingPagingItem {
      selectPagingItem(item, animated: true)
    }
  }
  
  fileprivate func handleStateUpdate(_ oldState: PagingState<T>, state: PagingState<T>, event: PagingEvent<T>?) {
    collectionViewLayout.state = state
    
    switch state {
    case let .selected(pagingItem):
      if let event = event {
        switch event {
        case .finishScrolling, .cancelScrolling:
          let animated = options.menuTransition == .animateAfter
          reloadItems(around: pagingItem)
          selectCollectionViewItem(for: pagingItem, animated: animated)
        default:
          break
        }
      }
    case .scrolling:
      let invalidationContext = PagingInvalidationContext()
      
      // When the old state is .selected it means that the user
      // just started scrolling.
      if case .selected = oldState {
        invalidationContext.invalidateTransition = true
      }
      
      invalidationContext.invalidateContentOffset = true
      collectionViewLayout.invalidateLayout(with: invalidationContext)
    }
  }
  
  fileprivate func handleStateMachineUpdate() {
    stateMachine?.didSelectPagingItem = { [weak self] pagingItem, direction, animated in
      self?.selectViewController(pagingItem, direction: direction, animated: animated)
    }
    
    stateMachine?.didChangeState = { [weak self] oldState, state, event in
      self?.handleStateUpdate(oldState, state: state, event: event)
    }
    
    stateMachine?.delegate = self
  }
  
  fileprivate func selectCollectionViewItem(for pagingItem: T, animated: Bool = false) {
    let indexPath = dataStructure.indexPathForPagingItem(pagingItem)
    let scrollPosition = options.scrollPosition
    
    collectionView.selectItem(
      at: indexPath,
      animated: animated,
      scrollPosition: scrollPosition)
  }
  
  fileprivate func generateItems(around pagingItem: T) -> Set<T> {
    
    var items: Set = [pagingItem]
    var previousItem: T = pagingItem
    var nextItem: T = pagingItem
    
    // Add as many items as we can before the current paging item to
    // fill up the same width as the bounds.
    var widthBefore: CGFloat = collectionView.bounds.width
    while widthBefore > 0 {
      if let item = dataSource?.pagingViewController(self, pagingItemBeforePagingItem: previousItem) {
        widthBefore -= itemWidth(pagingItem: item)
        previousItem = item
        items.insert(item)
      } else {
        break
      }
    }
    
    // When filling up the items after the current item we need to
    // include any remaining space left before the current item.
    var widthAfter: CGFloat = collectionView.bounds.width + widthBefore
    while widthAfter > 0 {
      if let item = dataSource?.pagingViewController(self, pagingItemAfterPagingItem: nextItem) {
        widthAfter -= itemWidth(pagingItem: item)
        nextItem = item
        items.insert(item)
      } else {
        break
      }
    }
    
    // Make sure we add even more items if there is any remaining
    // space available after filling items items after the current.
    var remainingWidth = widthAfter
    while remainingWidth > 0 {
      if let item = dataSource?.pagingViewController(self, pagingItemBeforePagingItem: previousItem) {
        remainingWidth -= itemWidth(pagingItem: item)
        previousItem = item
        items.insert(item)
      } else {
        break
      }
    }
    
    return items
  }
  
  fileprivate func reloadItems(around pagingItem: T) {
    
    let toItems = generateItems(around: pagingItem)
    let oldContentOffset = collectionView.contentOffset
    let oldDataStructure = dataStructure
    let sortedItems = Array(toItems).sorted()
    
    dataStructure = PagingDataStructure(
      visibleItems: toItems,
      hasItemsBefore: hasItemBefore(pagingItem: sortedItems.first),
      hasItemsAfter: hasItemAfter(pagingItem: sortedItems.last))
    
    collectionViewLayout.dataStructure = dataStructure
    collectionView.reloadData()
    
    // After reloading the data the content offset is going to be
    // reset. We need to diff which items where added/removed and
    // update the content offset so it looks it is the same as before
    // reloading. This gives the perception of a smooth scroll.
    var offset: CGFloat = 0
    let diff = PagingDiff(from: oldDataStructure, to: dataStructure)
    
    for indexPath in diff.removed() {
      offset += collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame.width ?? 0
      offset += options.menuItemSpacing
    }
    
    for indexPath in diff.added() {
      offset -= collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame.width ?? 0
      offset -= options.menuItemSpacing
    }
    
    collectionView.contentOffset = CGPoint(
      x: oldContentOffset.x - offset,
      y: oldContentOffset.y)
    
    // We need to perform layout here, if not the collection view
    // seems to get in a weird state.
    collectionView.layoutIfNeeded()
  }
  
  fileprivate func selectViewController(_ pagingItem: T, direction: PagingDirection, animated: Bool = true) {
    guard let dataSource = dataSource else { return }
    pageViewController.selectViewController(
      dataSource.pagingViewController(self, viewControllerForPagingItem: pagingItem),
      direction: direction.pageViewControllerNavigationDirection,
      animated: animated,
      completion: nil)
  }
  
  fileprivate func itemWidth(pagingItem: T) -> CGFloat {
    if let indexPath = dataStructure.indexPathForPagingItem(pagingItem) {
      let layoutAttributes = collectionViewLayout.layoutAttributesForItem(at: indexPath)
      return layoutAttributes?.frame.width ?? options.estimatedItemWidth
    } else {
      return options.estimatedItemWidth
    }
  }
  
  fileprivate func hasItemBefore(pagingItem: T?) -> Bool {
    guard let item = pagingItem else { return false }
    return dataSource?.pagingViewController(self, pagingItemBeforePagingItem: item) != nil
  }
  
  fileprivate func hasItemAfter(pagingItem: T?) -> Bool {
    guard let item = pagingItem else { return false }
    return dataSource?.pagingViewController(self, pagingItemAfterPagingItem: item) != nil
  }

  // MARK: UICollectionViewDelegate
  
  open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let stateMachine = stateMachine else { return }
    
    let currentPagingItem = stateMachine.state.currentPagingItem
    let selectedPagingItem = dataStructure.pagingItemForIndexPath(indexPath)
    let direction = dataStructure.directionForIndexPath(indexPath, currentPagingItem: currentPagingItem)

    stateMachine.fire(.select(
      pagingItem: selectedPagingItem,
      direction: direction,
      animated: true))
  }
  
  // MARK: UICollectionViewDataSource
  
  public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(indexPath: indexPath, cellType: options.menuItemClass)
    let pagingItem = dataStructure.sortedItems[indexPath.item]
    let selected = stateMachine?.state.currentPagingItem == pagingItem
    cell.setPagingItem(pagingItem, selected: selected, theme: options.theme)
    return cell
  }
  
  open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    return dataStructure.visibleItems.count
  }
  
  // MARK: EMPageViewControllerDataSource
  
  open func em_pageViewController(_ pageViewController: EMPageViewController, viewControllerBeforeViewController viewController: UIViewController) -> UIViewController? {
    guard
      let dataSource = dataSource,
      let state = stateMachine?.state.currentPagingItem,
      let pagingItem = dataSource.pagingViewController(self, pagingItemBeforePagingItem: state) else { return nil }
    
    return dataSource.pagingViewController(self, viewControllerForPagingItem: pagingItem)
  }
  
  open func em_pageViewController(_ pageViewController: EMPageViewController, viewControllerAfterViewController viewController: UIViewController) -> UIViewController? {
    guard
      let dataSource = dataSource,
      let state = stateMachine?.state.currentPagingItem,
      let pagingItem = dataSource.pagingViewController(self, pagingItemAfterPagingItem: state) else { return nil }
    
    return dataSource.pagingViewController(self, viewControllerForPagingItem: pagingItem)
  }
  
  // MARK: EMPageViewControllerDelegate

  open func em_pageViewController(_ pageViewController: EMPageViewController, isScrollingFrom startingViewController: UIViewController, destinationViewController: UIViewController?, progress: CGFloat) {
    stateMachine?.fire(.scroll(progress: progress))
  }
  
  open func em_pageViewController(_ pageViewController: EMPageViewController, didFinishScrollingFrom startingViewController: UIViewController?, destinationViewController: UIViewController, transitionSuccessful: Bool) {
    if transitionSuccessful {
      stateMachine?.fire(.finishScrolling)
    }
  }
  
  // MARK: PagingStateMachineDelegate
  
  func pagingStateMachine<U>(_ pagingStateMachine: PagingStateMachine<U>, pagingItemBeforePagingItem pagingItem: U) -> U? {
    guard let pagingItem = pagingItem as? T else { return nil }
    return dataSource?.pagingViewController(self, pagingItemBeforePagingItem: pagingItem) as? U
  }
  
  func pagingStateMachine<U>(_ pagingStateMachine: PagingStateMachine<U>, pagingItemAfterPagingItem pagingItem: U) -> U? {
    guard let pagingItem = pagingItem as? T else { return nil }
    return dataSource?.pagingViewController(self, pagingItemAfterPagingItem: pagingItem) as? U
  }
  
  // MARK: PagingCollectionViewLayoutDelegate
  
  func pagingCollectionViewLayout<U>(_ pagingCollectionViewLayout: PagingCollectionViewLayout<U>, widthForIndexPath indexPath: IndexPath) -> CGFloat {
    return delegate?.pagingViewController(self, widthForPagingItem: dataStructure.pagingItemForIndexPath(indexPath)) ?? 0
  }
  
}
