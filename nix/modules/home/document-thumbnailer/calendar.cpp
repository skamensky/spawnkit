// An iCalendar file as an event card: a calendar-leaf date, the title, when and where, who
// organises it and the start of its description. A file of several events lists the first.
#include "thumbnail.h"
#include <QLocale>
#include <QRegularExpression>
#include <QTimeZone>
#include <algorithm>

namespace {

struct Event {
    QString summary, location, description, organizer, repeats;
    QDateTime start, end;
    bool allDay = false;
    int attendees = 0;
};

struct Property {
    QString name, value;
    QHash<QString, QString> parameters;
};

// NAME;PARAM=VALUE;PARAM="QUOTED":VALUE, splitting at the first colon outside quotes.
Property parseLine(const QString &line) {
    Property p;
    bool quoted = false;
    qsizetype colon = -1;
    for (qsizetype i = 0; i < line.size(); ++i) {
        if (line[i] == u'"') quoted = !quoted;
        else if (line[i] == u':' && !quoted) {
            colon = i;
            break;
        }
    }
    if (colon < 0) return p;
    p.value = line.mid(colon + 1);
    const QStringList head = line.left(colon).split(u';');
    p.name = head.first().toUpper();
    for (qsizetype i = 1; i < head.size(); ++i) {
        const qsizetype eq = head[i].indexOf(u'=');
        if (eq > 0) p.parameters.insert(head[i].left(eq).toUpper(), head[i].mid(eq + 1).remove(u'"'));
    }
    return p;
}

QString unescape(const QString &value) {
    QString out;
    for (qsizetype i = 0; i < value.size(); ++i) {
        if (value[i] == u'\\' && i + 1 < value.size()) {
            const QChar c = value[++i];
            out += (c == u'n' || c == u'N') ? QChar(u'\n') : c;
        } else {
            out += value[i];
        }
    }
    return out;
}

// A DATE or DATE-TIME: UTC with a Z, in its TZID (an IANA or a Windows zone name), or local.
QDateTime parseTime(const Property &p, bool *allDay) {
    const QString v = p.value.trimmed();
    *allDay = v.size() == 8 || p.parameters.value(QStringLiteral("VALUE")) == u"DATE";
    if (*allDay) return QDateTime(QDate::fromString(v.left(8), QStringLiteral("yyyyMMdd")), QTime(0, 0));
    QDateTime t = QDateTime::fromString(v.left(15), QStringLiteral("yyyyMMdd'T'HHmmss"));
    if (!t.isValid()) return {};
    if (v.endsWith(u'Z')) {
        t.setTimeZone(QTimeZone::UTC);
    } else if (p.parameters.contains(QStringLiteral("TZID"))) {
        const QByteArray id = p.parameters.value(QStringLiteral("TZID")).toUtf8();
        QTimeZone zone(id);
        if (!zone.isValid()) zone = QTimeZone(QTimeZone::windowsIdToDefaultIanaId(id));
        if (zone.isValid()) t.setTimeZone(zone);
    }
    return t.toLocalTime();
}

QList<Event> parse(const QByteArray &data) {
    QString text = QString::fromUtf8(data);
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
    static const QRegularExpression folded(QStringLiteral("\n[ \t]"));
    text.remove(folded);
    QList<Event> events;
    QStringList components;
    for (const QString &line : text.split(u'\n')) {
        const Property p = parseLine(line);
        if (p.name == u"BEGIN") {
            components.append(p.value.trimmed().toUpper());
            if (components.last() == u"VEVENT") events.append(Event{});
            continue;
        }
        if (p.name == u"END") {
            if (!components.isEmpty()) components.removeLast();
            continue;
        }
        if (components.isEmpty() || components.last() != u"VEVENT") continue;
        Event &e = events.last();
        bool allDay = false;
        if (p.name == u"SUMMARY") e.summary = unescape(p.value);
        else if (p.name == u"LOCATION") e.location = unescape(p.value);
        else if (p.name == u"DESCRIPTION") e.description = unescape(p.value);
        else if (p.name == u"ORGANIZER") {
            e.organizer = p.parameters.value(QStringLiteral("CN"));
            if (e.organizer.isEmpty()) e.organizer = p.value.section(u':', -1);
        } else if (p.name == u"ATTENDEE") ++e.attendees;
        else if (p.name == u"DTSTART") {
            e.start = parseTime(p, &allDay);
            e.allDay = allDay;
        } else if (p.name == u"DTEND") e.end = parseTime(p, &allDay);
        else if (p.name == u"RRULE") {
            static const QRegularExpression freq(QStringLiteral("FREQ=([A-Z]+)"));
            const QString f = freq.match(p.value).captured(1).toLower();
            if (!f.isEmpty()) e.repeats = QStringLiteral("Repeats ") + f;
        }
    }
    events.removeIf([](const Event &e) { return !e.start.isValid(); });
    std::sort(events.begin(), events.end(), [](const Event &a, const Event &b) { return a.start < b.start; });
    return events;
}

QString when(const Event &e) {
    const QLocale locale = QLocale::system();
    QString s = locale.toString(e.start.date(), QLocale::LongFormat);
    if (e.allDay) {
        const QDate last = e.end.isValid() ? e.end.date().addDays(-1) : e.start.date();
        if (last > e.start.date()) s += QStringLiteral(" – ") + locale.toString(last, QLocale::LongFormat);
        return s;
    }
    s += QStringLiteral(" · ") + locale.toString(e.start.time(), QLocale::ShortFormat);
    if (e.end.isValid() && e.end > e.start) {
        s += QStringLiteral(" – ");
        if (e.end.date() != e.start.date()) s += locale.toString(e.end.date(), QLocale::ShortFormat) + u' ';
        s += locale.toString(e.end.time(), QLocale::ShortFormat);
    }
    return s;
}

// The calendar leaf: the month on a red band above the day of the month.
QString leaf(const QDate &date, int scale) {
    const QLocale locale = QLocale::system();
    return QStringLiteral(
               "<table cellspacing='0' cellpadding='%1' width='%2' style='border: 1px solid #d1d9e0'>"
               "<tr><td bgcolor='#cf222e' align='center'><span style='color: white; font-size: %3px; font-weight: 600'>%4</span></td></tr>"
               "<tr><td align='center'><span style='font-size: %5px; font-weight: 600'>%6</span>%7</td></tr></table>")
        .arg(scale * 2)
        .arg(scale * 28)
        .arg(scale * 4 + 2)
        .arg(locale.monthName(date.month(), QLocale::ShortFormat).toUpper())
        .arg(scale * 12)
        .arg(date.day())
        .arg(scale > 2 ? QStringLiteral("<br><span style='color: #59636e'>%1</span>").arg(locale.dayName(date.dayOfWeek())) : QString());
}

QString paragraph(const QString &text, const QString &style) {
    return QStringLiteral("<p style='margin-bottom: 8px; %1'>%2</p>").arg(style, text.toHtmlEscaped().replace(u'\n', QStringLiteral("<br>")));
}

QString details(const Event &e, bool full) {
    QString html = paragraph(e.summary.isEmpty() ? QStringLiteral("(No title)") : e.summary,
                             full ? QStringLiteral("font-size: 28px; font-weight: 600") : QStringLiteral("font-size: 19px; font-weight: 600"));
    html += paragraph(when(e) + (e.repeats.isEmpty() ? QString() : QStringLiteral(" · ") + e.repeats), QString());
    if (!e.location.isEmpty()) html += paragraph(e.location, QStringLiteral("color: #59636e"));
    if (!full) return html;
    QStringList people;
    if (!e.organizer.isEmpty()) people << QStringLiteral("Organised by ") + e.organizer;
    if (e.attendees) people << QStringLiteral("%1 invited").arg(e.attendees);
    if (!people.isEmpty()) html += paragraph(people.join(QStringLiteral(" · ")), QStringLiteral("color: #59636e"));
    // The start of the description, without the rules that meeting invitations draw.
    static const QRegularExpression rules(QStringLiteral("[_=~─-]{5,}"));
    QString description = e.description;
    description.remove(rules);
    description = description.trimmed();
    static const QRegularExpression blankLines(QStringLiteral("\n\\s*\n+"));
    description.replace(blankLines, QStringLiteral("\n"));
    if (description.size() > 500) description = description.left(499) + QChar(0x2026);
    if (!description.isEmpty()) html += QStringLiteral("<hr>") + paragraph(description, QStringLiteral("color: #59636e; font-size: 15px"));
    return html;
}

} // namespace

bool renderCalendar(QTextDocument &doc, const QByteArray &data) {
    const QList<Event> events = parse(data);
    if (events.isEmpty()) return false;
    QString html;
    if (events.size() == 1) {
        html = QStringLiteral("<table cellspacing='0' cellpadding='0' width='100%'><tr><td width='130' valign='top'>%1</td><td width='28'></td>"
                              "<td valign='top'>%2</td></tr></table>")
                   .arg(leaf(events[0].start.date(), 4), details(events[0], true));
    } else {
        html = paragraph(QStringLiteral("%1 events").arg(events.size()), QStringLiteral("font-size: 17px; color: #59636e"));
        html += QStringLiteral("<table cellspacing='0' cellpadding='0' width='100%'>");
        for (qsizetype i = 0; i < qMin<qsizetype>(events.size(), 6); ++i) {
            html += QStringLiteral("<tr><td width='60' valign='top' style='padding-bottom: 18px'>%1</td><td width='20'></td><td valign='top'>%2</td></tr>")
                        .arg(leaf(events[i].start.date(), 2), details(events[i], false));
        }
        html += QStringLiteral("</table>");
    }
    doc.setHtml(QStringLiteral("<body style='color: #1f2328'>") + html + QStringLiteral("</body>"));
    return true;
}
