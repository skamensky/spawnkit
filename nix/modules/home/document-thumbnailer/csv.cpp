// A delimited table as a spreadsheet grid: the first row as a shaded header, numbers aligned
// right, alternate rows striped. Only the rows and columns that fit a page are read.
#include "thumbnail.h"
#include <QRegularExpression>
#include <QTextCursor>
#include <QTextTable>
#include <algorithm>

namespace {

constexpr int maxRows = 45, maxColumns = 10, maxCell = 28;

// Splits RFC 4180 records: quoted fields may hold the delimiter, doubled quotes and newlines.
QList<QStringList> parse(const QString &text, QChar delimiter) {
    QList<QStringList> rows;
    QStringList row;
    QString field;
    bool quoted = false;
    for (qsizetype i = 0; i < text.size() && rows.size() <= maxRows; ++i) {
        const QChar c = text[i];
        if (quoted) {
            if (c != u'"') field += c;
            else if (i + 1 < text.size() && text[i + 1] == u'"') field += text[++i];
            else quoted = false;
        } else if (c == u'"') {
            quoted = true;
        } else if (c == delimiter) {
            row.append(field);
            field.clear();
        } else if (c == u'\n' || c == u'\r') {
            if (c == u'\r' && i + 1 < text.size() && text[i + 1] == u'\n') ++i;
            row.append(field);
            field.clear();
            if (!(row.size() == 1 && row[0].isEmpty())) rows.append(row);
            row.clear();
        } else {
            field += c;
        }
    }
    if (!field.isEmpty() || !row.isEmpty()) rows.append(row << field);
    return rows;
}

// The delimiter that the first line uses most, outside quotes.
QChar detectDelimiter(const QString &text) {
    const QString candidates = QStringLiteral(",;\t|");
    QList<int> counts(candidates.size());
    bool quoted = false;
    for (const QChar c : text) {
        if (c == u'"') quoted = !quoted;
        else if (!quoted && (c == u'\n' || c == u'\r')) break;
        else if (!quoted && candidates.contains(c)) ++counts[candidates.indexOf(c)];
    }
    const auto best = std::max_element(counts.begin(), counts.end());
    return *best ? candidates[best - counts.begin()] : QChar(u',');
}

} // namespace

bool renderCsv(QTextDocument &doc, const QByteArray &data, char delimiter) {
    QString text = QString::fromUtf8(data);
    if (text.startsWith(QChar(0xfeff))) text.remove(0, 1);
    const QList<QStringList> rows = parse(text, delimiter ? QChar(delimiter) : detectDelimiter(text));
    if (rows.isEmpty()) return false;
    qsizetype columns = 0;
    for (const QStringList &row : rows) columns = qMax(columns, row.size());
    const bool moreColumns = columns > maxColumns;
    const int shown = int(qMin<qsizetype>(columns, maxColumns));
    const int shownRows = int(qMin<qsizetype>(rows.size(), maxRows));

    static const QRegularExpression number(QStringLiteral(R"(^\s*[-+(]?[$€£₪]?\s*\d[\d,. ]*(?:[eE][-+]?\d+)?\s*[%)]?\s*$)"));
    QFont font = doc.defaultFont();
    font.setPixelSize(13);
    doc.setDefaultFont(font);
    doc.setDocumentMargin(20);
    QTextCursor cursor(&doc);
    QTextTableFormat tableFormat;
    tableFormat.setCellPadding(5);
    tableFormat.setCellSpacing(0);
    tableFormat.setBorder(1);
    tableFormat.setBorderStyle(QTextFrameFormat::BorderStyle_Solid);
    tableFormat.setBorderBrush(rule);
    tableFormat.setBorderCollapse(true);
    tableFormat.setHeaderRowCount(1);
    QTextTable *table = cursor.insertTable(shownRows + (rows.size() > maxRows), shown + moreColumns, tableFormat);
    const auto fill = [&](int r, int c, const QString &value, bool header, bool stripe) {
        QTextTableCell cell = table->cellAt(r, c);
        QTextCharFormat cellFormat = cell.format();
        if (header) cellFormat.setBackground(QColor(0xea, 0xee, 0xf2));
        else if (stripe) cellFormat.setBackground(codeBackground);
        cell.setFormat(cellFormat);
        QTextCursor at = cell.firstCursorPosition();
        QTextBlockFormat block;
        block.setAlignment(!header && number.match(value).hasMatch() ? Qt::AlignRight : Qt::AlignLeft);
        block.setNonBreakableLines(true);
        at.setBlockFormat(block);
        QTextCharFormat format;
        if (header) format.setFontWeight(QFont::DemiBold);
        format.setForeground(ink);
        QString shownValue = value.simplified();
        if (shownValue.size() > maxCell) shownValue = shownValue.left(maxCell - 1) + QChar(0x2026);
        at.insertText(shownValue, format);
    };
    for (int r = 0; r < shownRows; ++r) {
        for (int c = 0; c < shown; ++c) fill(r, c, c < rows[r].size() ? rows[r][c] : QString(), r == 0, r % 2 == 0);
        if (moreColumns) fill(r, shown, QStringLiteral("…"), r == 0, r % 2 == 0);
    }
    if (rows.size() > maxRows) {
        for (int c = 0; c < shown + moreColumns; ++c) fill(shownRows, c, QStringLiteral("⋮"), false, false);
    }
    // A narrow table gets a page of about its own width, so the thumbnail shows it larger.
    doc.setTextWidth(qBound(pageWidth / 2, doc.idealWidth(), pageWidth));
    return true;
}
