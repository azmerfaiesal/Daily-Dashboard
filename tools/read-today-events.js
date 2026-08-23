// Reads today's Apple Calendar events via EventKit and prints them as JSON.
//
// EventKit is used rather than automating Calendar.app: it is far faster, needs no
// AppleScript bridge, and returns occurrences of recurring events already expanded.
//
// Run with:  osascript -l JavaScript tools/read-today-events.js
// The first run raises the macOS calendar-access prompt; approve it once.

ObjC.import('EventKit');
ObjC.import('Foundation');

function pad(n) { return String(n).padStart(2, '0'); }
function dateStr(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
function isoFrom(nsDate) { return new Date(nsDate.timeIntervalSince1970 * 1000).toISOString(); }

// Returns 'granted' | 'denied' | 'timeout'. The distinction matters: under launchd
// the very first run has to raise the macOS permission prompt, and if nobody is at the
// keyboard it simply expires — which is a completely different problem from an
// explicit denial, and needs a different fix.
function requestAccess(store) {
  var done = false, granted = false;
  // macOS 14 replaced requestAccessToEntityType with requestFullAccessToEvents.
  if (typeof store.requestFullAccessToEventsCompletion === 'function') {
    store.requestFullAccessToEventsCompletion(function (g) { granted = g; done = true; });
  } else {
    store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent, function (g) { granted = g; done = true; });
  }
  // The completion handler only fires while a run loop is spinning. The window is
  // generous because the first run may be waiting on a human to click Allow.
  var deadline = $.NSDate.dateWithTimeIntervalSinceNow(120);
  while (!done && $.NSDate.date.compare(deadline) < 0) {
    $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode,
      $.NSDate.dateWithTimeIntervalSinceNow(0.1));
  }
  if (!done) return 'timeout';
  return granted ? 'granted' : 'denied';
}

function run() {
  var store = $.EKEventStore.alloc.init;
  var access = requestAccess(store);
  if (access !== 'granted') {
    return JSON.stringify({ error: 'no-calendar-access', reason: access });
  }

  var now = new Date();
  var today = dateStr(now);
  var start = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0);
  var end = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59);

  var pred = store.predicateForEventsWithStartDateEndDateCalendars(
    $.NSDate.dateWithTimeIntervalSince1970(start.getTime() / 1000),
    $.NSDate.dateWithTimeIntervalSince1970(end.getTime() / 1000),
    $()                       // $() = all calendars
  );

  var events = store.eventsMatchingPredicate(pred);
  var out = [];
  for (var i = 0; i < events.count; i++) {
    var e = events.objectAtIndex(i);
    var title = ObjC.unwrap(e.title);
    var loc = ObjC.unwrap(e.location);
    var cal = ObjC.unwrap(e.calendar.title);
    out.push({
      // Occurrences of a recurring event share one eventIdentifier, so the date is
      // appended to keep one stable row per day rather than overwriting each other.
      id: ObjC.unwrap(e.eventIdentifier) + '@' + today,
      title: title || '',
      location: loc || null,
      calendar_name: cal || '',
      all_day: !!e.isAllDay,
      starts_at: isoFrom(e.startDate),
      ends_at: e.endDate ? isoFrom(e.endDate) : null,
      event_date: today
    });
  }
  return JSON.stringify(out);
}
