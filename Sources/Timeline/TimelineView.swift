import UIKit

public protocol TimelineViewDelegate: AnyObject {
  func timelineView(_ timelineView: TimelineView, didTapAt date: Date)
  func timelineView(_ timelineView: TimelineView, didLongPressAt date: Date)
  func timelineView(_ timelineView: TimelineView, didTap event: EventView)
  func timelineView(_ timelineView: TimelineView, didLongPress event: EventView)
}

public final class TimelineView: UIView {
    public weak var delegate: TimelineViewDelegate?
    public weak var dayModelDataSource: DayModelDataSource? {
        didSet {
            guard dayModelDataSource != nil else {
                return
            }

            setNeedsLayout()
        }
    }

  public var date = Date() {
    didSet {
      setNeedsLayout()
    }
  }

  private var currentTime: Date {
    return Date()
  }

  private var eventViews = [EventView]()
  public private(set) var regularLayoutAttributes = [EventLayoutAttributes]()
  public private(set) var allDayLayoutAttributes = [EventLayoutAttributes]()
  
  public var layoutAttributes: [EventLayoutAttributes] {
    set {
      
      // update layout attributes by separating allday from non all day events
      allDayLayoutAttributes.removeAll()
      regularLayoutAttributes.removeAll()
      for anEventLayoutAttribute in newValue {
        let eventDescriptor = anEventLayoutAttribute.descriptor
        if eventDescriptor.isAllDay {
          allDayLayoutAttributes.append(anEventLayoutAttribute)
        } else {
          regularLayoutAttributes.append(anEventLayoutAttribute)
        }
      }
      
      recalculateEventLayout()
      prepareEventViews()
      
      setNeedsLayout()
    }
    get {
      return allDayLayoutAttributes + regularLayoutAttributes
    }
  }
  private var pool = ReusePool<EventView>()

  public var firstEventYPosition: CGFloat? {
    let first = regularLayoutAttributes.sorted{$0.frame.origin.y < $1.frame.origin.y}.first
    guard let firstEvent = first else {return nil}
    let firstEventPosition = firstEvent.frame.origin.y
    let beginningOfDayPosition = dateToY(date)
    return max(firstEventPosition, beginningOfDayPosition)
  }

  private lazy var nowLine: CurrentTimeIndicator = CurrentTimeIndicator()
    
  var style = TimelineStyle()

  public var calendarWidth: CGFloat {
    return bounds.width
  }
    
  public private(set) var is24hClock = true {
    didSet {
      setNeedsDisplay()
    }
  }

  public var calendar: Calendar = Calendar.autoupdatingCurrent {
    didSet {
      eventEditingSnappingBehavior.calendar = calendar
      nowLine.calendar = calendar
      regenerateTimeStrings()
      setNeedsLayout()
    }
  }

  public var eventEditingSnappingBehavior: EventEditingSnappingBehavior = SnapTo15MinuteIntervals() {
    didSet {
      eventEditingSnappingBehavior.calendar = calendar
    }
  }

  private var times: [String] {
    return is24hClock ? _24hTimes : _12hTimes
  }

  private lazy var _12hTimes: [String] = TimeStringsFactory(calendar).make12hStrings()
  private lazy var _24hTimes: [String] = TimeStringsFactory(calendar).make24hStrings()
  
  private func regenerateTimeStrings() {
    let factory = TimeStringsFactory(calendar)
    _12hTimes = factory.make12hStrings()
    _24hTimes = factory.make24hStrings()
  }
  
  public lazy var longPressGestureRecognizer = UILongPressGestureRecognizer(target: self,
                                                                            action: #selector(longPress(_:)))

  public lazy var tapGestureRecognizer = UITapGestureRecognizer(target: self,
                                                                action: #selector(tap(_:)))

  private var isToday: Bool {
    return calendar.isDateInToday(date)
  }
  
  // MARK: - Initialization
  
  public init() {
    super.init(frame: .zero)
    frame.size.height = fullHeight()
    configure()
  }

  override public init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    configure()
  }

  private func configure() {
    contentScaleFactor = 1
    layer.contentsScale = 1
    contentMode = .redraw
    backgroundColor = .white
//    addSubview(nowLine)
    
    // Add long press gesture recognizer
    addGestureRecognizer(longPressGestureRecognizer)
    addGestureRecognizer(tapGestureRecognizer)
  }
    
    func fullHeight() -> CGFloat {
        func height(for hours: Int) -> CGFloat {
            return style.verticalInset * 2 + style.verticalDiff * CGFloat(hours)
        }
        
        guard let dayModel = dayModelDataSource?.dayModel(for: date) else {
            return height(for: 24) // default value -- full day
        }
        
        return height(for: dayModel.totalWorkingHours)
    }
  
  // MARK: - Event Handling
  
  @objc private func longPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
    if (gestureRecognizer.state == .began) {
      // Get timeslot of gesture location
      let pressedLocation = gestureRecognizer.location(in: self)
      if let eventView = findEventView(at: pressedLocation) {
        delegate?.timelineView(self, didLongPress: eventView)
      } else {
        delegate?.timelineView(self, didLongPressAt: yToDate(pressedLocation.y))
      }
    }
  }
  
  @objc private func tap(_ sender: UITapGestureRecognizer) {
    let pressedLocation = sender.location(in: self)
    if let eventView = findEventView(at: pressedLocation) {
      delegate?.timelineView(self, didTap: eventView)
    } else {
      delegate?.timelineView(self, didTapAt: yToDate(pressedLocation.y))
    }
  }
  
  private func findEventView(at point: CGPoint) -> EventView? {
    for eventView in eventViews {
      let frame = eventView.frame
      if frame.contains(point) {
        return eventView
      }
    }
    return nil
  }
  
  // MARK: - Style

  public func updateStyle(_ newStyle: TimelineStyle) {
    style = newStyle
    nowLine.updateStyle(style.timeIndicator)
    
    switch style.dateStyle {
      case .twelveHour:
        is24hClock = false
      case .twentyFourHour:
        is24hClock = true
      default:
        is24hClock = calendar.locale?.uses24hClock() ?? Locale.autoupdatingCurrent.uses24hClock()
    }
    
    backgroundColor = style.backgroundColor
    setNeedsDisplay()
  }
  
  // MARK: - Background Pattern

  public var accentedDate: Date?

  override public func draw(_ rect: CGRect) {
    super.draw(rect)

    var hourToRemoveIndex = -1

    var accentedHour = -1
    var accentedMinute = -1

//    if let accentedDate = accentedDate {
//      accentedHour = eventEditingSnappingBehavior.accentedHour(for: accentedDate)
//      accentedMinute = eventEditingSnappingBehavior.accentedMinute(for: accentedDate)
//    }
//
//    if isToday {
//      let minute = component(component: .minute, from: currentTime)
//      let hour = component(component: .hour, from: currentTime)
//      if minute > 39 {
//        hourToRemoveIndex = hour + 1
//      } else if minute < 21 {
//        hourToRemoveIndex = hour
//      }
//    }

    let mutableParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
    mutableParagraphStyle.lineBreakMode = .byWordWrapping
    mutableParagraphStyle.alignment = .right
    let paragraphStyle = mutableParagraphStyle.copy() as! NSParagraphStyle

    let attributes = [NSAttributedString.Key.paragraphStyle: paragraphStyle,
                      NSAttributedString.Key.foregroundColor: self.style.timeColor,
                      NSAttributedString.Key.font: style.font] as [NSAttributedString.Key : Any]

      let scale = UIScreen.main.scale
      let hourLineHeight = Constants.hourLineHeight / scale

    let center: CGFloat
    if Int(scale) % 2 == 0 {
        center = 1 / (scale * 2)
    } else {
        center = 0
    }
    
    let offset = 0.5 - center
      
      let rightToLeft = UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft
      let xEnd: CGFloat = {
          if rightToLeft {
              return 0
          } else {
              return bounds.width - style.trailingInset
          }
      }()
      
      let context = UIGraphicsGetCurrentContext()
      context?.saveGState()
//      context?.setFillColor(UIColor.green.cgColor)
//      context?.fill(.init(origin: .init(x: style.leadingInset + 29, y: 0),
//                          size: .init(width: calendarWidth, height: fullHeight)))
//      context?.restoreGState()
    
      let times: [String]
      if let dayModel = dayModelDataSource?.dayModel(for: date) {
          times = TimeStringsFactory().make24hStrings(with: dayModel.startHour, endHour: dayModel.endHour)
      } else {
          times = self.times
      }
      
    for (hour, time) in times.enumerated() {
        let hourFloat = CGFloat(hour)
        let timeString = NSString(string: time)
        let fontSize = style.font.pointSize
        let timeSize = timeString.boundingRect(with: bounds.size,
                                               options: .usesLineFragmentOrigin,
                                               attributes: attributes,
                                               context: nil)
        
        context?.interpolationQuality = .none
        context?.saveGState()
        context?.setStrokeColor(style.separatorColor.cgColor)
        context?.setLineWidth(hourLineHeight)
        
        let y = style.verticalInset + hourFloat * style.verticalDiff + offset
        let xStart = style.leadingInset + timeSize.width + style.separatorInset
        context?.beginPath()
        context?.move(to: CGPoint(x: xStart, y: y))
        context?.addLine(to: CGPoint(x: xEnd, y: y))
        context?.strokePath()
        context?.restoreGState()
    
        if hour == hourToRemoveIndex { continue }
        
        let timeRect: CGRect = {
            var x: CGFloat
            if rightToLeft {
                x = bounds.width - style.leadingInset - timeSize.width
            } else {
                x = style.leadingInset
            }
            
            return CGRect(x: x,
                          y: hourFloat * style.verticalDiff + style.verticalInset - 7,
                          width: timeSize.width,
                          height: fontSize + 2)
        }()
        
        timeString.draw(in: timeRect, withAttributes: attributes)
    
        if accentedMinute == 0 {
            continue
        }
    
        if hour == accentedHour {
            
            var x: CGFloat
            if UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft {
                x = bounds.width - (style.leadingInset + 7)
            } else {
                x = 2
            }
            
            let timeRect = CGRect(x: x, y: hourFloat * style.verticalDiff + style.verticalInset - 7     + style.verticalDiff * (CGFloat(accentedMinute) / 60),
                                width: style.leadingInset - 8, height: fontSize + 2)
            
            let timeString = NSString(string: ":\(accentedMinute)")
            
            timeString.draw(in: timeRect, withAttributes: attributes)
        }
    }
      
      
  }
  
  // MARK: - Layout

  override public func layoutSubviews() {
    super.layoutSubviews()
    recalculateEventLayout()
    layoutEvents()
//    layoutNowLine()
  }

  private func layoutNowLine() {
    if !isToday {
      nowLine.alpha = 0
    } else {
		bringSubviewToFront(nowLine)
      nowLine.alpha = 1
      let size = CGSize(width: bounds.size.width, height: 20)
      let rect = CGRect(origin: CGPoint.zero, size: size)
      nowLine.date = currentTime
      nowLine.frame = rect
      nowLine.center.y = dateToY(currentTime)
    }
  }

    private func layoutEvents() {
        if eventViews.isEmpty { return }
        
        for (idx, attributes) in regularLayoutAttributes.enumerated() {
            let descriptor = attributes.descriptor
            let eventView = eventViews[idx]
            eventView.frame = attributes.frame
            
            var x: CGFloat
            if UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft {
                x = bounds.width - attributes.frame.minX - attributes.frame.width
            } else {
                x = attributes.frame.minX
            }
            
            eventView.frame = CGRect(x: x,
                                     y: attributes.frame.minY,
                                     width: attributes.frame.width,
                                     height: attributes.frame.height - style.eventGap)
            eventView.updateWithDescriptor(event: descriptor)
            
            let eventMinY = attributes.frame.minY
            let isHidden = (eventMinY < 0) || (eventMinY > fullHeight())
            eventView.isHidden = isHidden
        }
    }
    
  private func recalculateEventLayout() {

    // only non allDay events need their frames to be set
    let sortedEvents = self.regularLayoutAttributes.sorted { (attr1, attr2) -> Bool in
      let start1 = attr1.descriptor.startDate
      let start2 = attr2.descriptor.startDate
      return start1 < start2
    }

    var groupsOfEvents = [[EventLayoutAttributes]]()
    var overlappingEvents = [EventLayoutAttributes]()

    for event in sortedEvents {
      if overlappingEvents.isEmpty {
        overlappingEvents.append(event)
        continue
      }

      let longestEvent = overlappingEvents.sorted { (attr1, attr2) -> Bool in
        var period = attr1.descriptor.datePeriod
        let period1 = period.upperBound.timeIntervalSince(period.lowerBound)
        period = attr2.descriptor.datePeriod
        let period2 = period.upperBound.timeIntervalSince(period.lowerBound)

        return period1 > period2
        }
        .first!

      if style.eventsWillOverlap {
        guard let earliestEvent = overlappingEvents.first?.descriptor.startDate else { continue }
        let dateInterval = getDateInterval(date: earliestEvent)
        if event.descriptor.datePeriod.contains(dateInterval.lowerBound) {
          overlappingEvents.append(event)
          continue
        }
      } else {
        let lastEvent = overlappingEvents.last!
        if (longestEvent.descriptor.datePeriod.overlaps(event.descriptor.datePeriod) && (longestEvent.descriptor.endDate != event.descriptor.startDate || style.eventGap <= 0.0)) ||
          (lastEvent.descriptor.datePeriod.overlaps(event.descriptor.datePeriod) && (lastEvent.descriptor.endDate != event.descriptor.startDate || style.eventGap <= 0.0)) {
          overlappingEvents.append(event)
          continue
        }
      }
      groupsOfEvents.append(overlappingEvents)
      overlappingEvents = [event]
    }

    groupsOfEvents.append(overlappingEvents)
    overlappingEvents.removeAll()
      
      for overlappingEvents in groupsOfEvents {
          let totalCount = CGFloat(overlappingEvents.count)
          for (index, event) in overlappingEvents.enumerated() {
              let startY = dateToY(event.descriptor.datePeriod.lowerBound) + Constants.hourLineHeight
              let endY = dateToY(event.descriptor.datePeriod.upperBound)
              let floatIndex = CGFloat(index)
              // FIXME: leadingInset + 29 because originally it was 53. It lays out from
              // left side but it doesn't take into account that time label
              // also has some width. And for `equalWidth` (-5) because of
              // the above + 29 :(
              let x = style.leadingInset + 31 + style.separatorInset + floatIndex / totalCount * calendarWidth
              let equalWidth = (calendarWidth - x - style.trailingInset) / totalCount
              event.frame = CGRect(x: x, y: startY, width: equalWidth, height: endY - startY)
          }
      }
  }

  private func prepareEventViews() {
    pool.enqueue(views: eventViews)
    eventViews.removeAll()
    for _ in regularLayoutAttributes {
      let newView = pool.dequeue()
      if newView.superview == nil {
        addSubview(newView)
      }
      eventViews.append(newView)
    }
  }

  public func prepareForReuse() {
    pool.enqueue(views: eventViews)
    eventViews.removeAll()
    setNeedsDisplay()
  }

  // MARK: - Helpers

  public func dateToY(_ date: Date) -> CGFloat {
    let provisionedDate = date.dateOnly(calendar: calendar)
    let timelineDate = self.date.dateOnly(calendar: calendar)
    var dayOffset: CGFloat = 0
    if provisionedDate > timelineDate {
      // Event ending the next day
      dayOffset += 1
    } else if provisionedDate < timelineDate {
      // Event starting the previous day
      dayOffset -= 1
    }
      
      let verticalDiff = style.verticalDiff
      let totalHours: CGFloat
      let timeOffset: CGFloat // because day might not start from 00:00
      if let model = dayModelDataSource?.dayModel(for: self.date) {
          totalHours = CGFloat(model.totalWorkingHours)
          timeOffset = -(CGFloat(model.startHour) * verticalDiff)
      } else {
          totalHours = 24
          timeOffset = 0
      }
    let fullTimelineHeight = totalHours * style.verticalDiff
    let hour = component(component: .hour, from: date)
    let minute = component(component: .minute, from: date)
    let hourY = CGFloat(hour) * style.verticalDiff + style.verticalInset
    let minuteY = CGFloat(minute) * style.verticalDiff / 60
    return timeOffset + hourY + minuteY + fullTimelineHeight * dayOffset
  }

    // if we wanna support reordering etc
    // here we should consider startOfTheDay delta
  public func yToDate(_ y: CGFloat) -> Date {
    let timeValue = y - style.verticalInset
    var hour = Int(timeValue / style.verticalDiff)
    let fullHourPoints = CGFloat(hour) * style.verticalDiff
    let minuteDiff = timeValue - fullHourPoints
    let minute = Int(minuteDiff / style.verticalDiff * 60)
    var dayOffset = 0
    if hour > 23 {
      dayOffset += 1
      hour -= 24
    } else if hour < 0 {
      dayOffset -= 1
      hour += 24
    }
    let offsetDate = calendar.date(byAdding: DateComponents(day: dayOffset),
                                   to: date)!
    let newDate = calendar.date(bySettingHour: hour,
                                minute: minute.clamped(to: 0...59),
                                second: 0,
                                of: offsetDate)
    return newDate!
  }

  private func component(component: Calendar.Component, from date: Date) -> Int {
    return calendar.component(component, from: date)
  }
  
  private func getDateInterval(date: Date) -> ClosedRange<Date> {
    let earliestEventMintues = component(component: .minute, from: date)
    let splitMinuteInterval = style.splitMinuteInterval
    let minute = component(component: .minute, from: date)
    let minuteRange = (minute / splitMinuteInterval) * splitMinuteInterval
    let beginningRange = calendar.date(byAdding: .minute, value: -(earliestEventMintues - minuteRange), to: date)!
    let endRange = calendar.date(byAdding: .minute, value: splitMinuteInterval, to: beginningRange)!
    return beginningRange ... endRange
  }
    
    private struct Constants {
        static let hourLineHeight: CGFloat = 1
    }
}
