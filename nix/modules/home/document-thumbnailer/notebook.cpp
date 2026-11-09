// A Jupyter notebook as nbviewer shows it: Markdown cells rendered, code cells highlighted in
// the kernel's language, and beneath each its printed output and plots. The cells become one
// Markdown document that renderMarkdown lays out, with output images as named resources.
#include "thumbnail.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

namespace {

constexpr int maxCells = 40, maxOutputLines = 16, maxLines = 160;

// Notebook text is a string or a list of lines.
QString joined(const QJsonValue &value) {
    if (!value.isArray()) return value.toString();
    QString text;
    for (const QJsonValue &line : value.toArray()) text += line.toString();
    return text;
}

// A fence longer than any backtick run inside the text.
QString fence(const QString &language, QString text) {
    static const QRegularExpression ticks(QStringLiteral("`{3,}"));
    qsizetype longest = 2;
    for (const auto &m : ticks.globalMatch(text)) longest = qMax(longest, m.capturedLength());
    const QString marks(longest + 1, u'`');
    while (text.endsWith(u'\n')) text.chop(1);
    return marks + language + u'\n' + text + u'\n' + marks + QStringLiteral("\n\n");
}

QString firstLines(QString text) {
    static const QRegularExpression ansi(QStringLiteral("\x1b\\[[0-9;]*[A-Za-z]"));
    text.remove(ansi);
    QStringList lines = text.split(u'\n');
    while (!lines.isEmpty() && lines.last().trimmed().isEmpty()) lines.removeLast();
    if (lines.size() > maxOutputLines) lines = lines.mid(0, maxOutputLines - 1) << QStringLiteral("…");
    return lines.join(u'\n');
}

} // namespace

bool renderNotebook(QTextDocument &doc, const QByteArray &data) {
    const QJsonObject notebook = QJsonDocument::fromJson(data).object();
    // nbformat 4 keeps cells at the top; nbformat 3 in its first worksheet.
    QJsonArray cells = notebook.value(QStringLiteral("cells")).toArray();
    if (cells.isEmpty()) cells = notebook.value(QStringLiteral("worksheets")).toArray().at(0).toObject().value(QStringLiteral("cells")).toArray();
    if (cells.isEmpty()) return false;
    const QJsonObject metadata = notebook.value(QStringLiteral("metadata")).toObject();
    QString language = metadata.value(QStringLiteral("language_info")).toObject().value(QStringLiteral("name")).toString();
    if (language.isEmpty()) language = metadata.value(QStringLiteral("kernelspec")).toObject().value(QStringLiteral("language")).toString();
    if (language.isEmpty()) language = QStringLiteral("python");

    QString markdown;
    QHash<QString, QImage> images;
    const auto addImage = [&](const QString &key, const QJsonValue &base64) {
        QImage image;
        if (image.loadFromData(QByteArray::fromBase64(joined(base64).toLatin1()))) images.insert(key, image);
        return images.contains(key);
    };
    int cellCount = 0;
    for (const QJsonValue &value : cells) {
        if (++cellCount > maxCells || markdown.count(u'\n') > maxLines) break;
        const QJsonObject cell = value.toObject();
        const QString type = cell.value(QStringLiteral("cell_type")).toString();
        if (type == u"markdown" || type == u"heading") {
            const QJsonObject attachments = cell.value(QStringLiteral("attachments")).toObject();
            for (auto it = attachments.begin(); it != attachments.end(); ++it) {
                const QJsonObject bundle = it.value().toObject();
                for (auto b = bundle.begin(); b != bundle.end(); ++b) {
                    if (b.key().startsWith(QStringLiteral("image/")) && addImage(QStringLiteral("attachment:") + it.key(), b.value())) break;
                }
            }
            markdown += joined(cell.value(QStringLiteral("source"))) + QStringLiteral("\n\n");
            continue;
        }
        if (type != u"code") continue;
        QString source = joined(cell.value(QStringLiteral("source")));
        if (source.isEmpty()) source = joined(cell.value(QStringLiteral("input")));
        markdown += fence(language, source);
        for (const QJsonValue &outputValue : cell.value(QStringLiteral("outputs")).toArray()) {
            const QJsonObject output = outputValue.toObject();
            const QString outputType = output.value(QStringLiteral("output_type")).toString();
            if (outputType == u"error" || outputType == u"pyerr") {
                markdown += fence(QStringLiteral("output"), output.value(QStringLiteral("ename")).toString() + QStringLiteral(": ") +
                                                             firstLines(output.value(QStringLiteral("evalue")).toString()));
                continue;
            }
            // nbformat 4 keys each representation by MIME type; nbformat 3 by a short name.
            const QJsonObject bundle = output.contains(QStringLiteral("data")) ? output.value(QStringLiteral("data")).toObject() : output;
            const QString key = QStringLiteral("output:%1").arg(images.size());
            if ((bundle.contains(QStringLiteral("image/png")) && addImage(key, bundle.value(QStringLiteral("image/png")))) ||
                (bundle.contains(QStringLiteral("image/jpeg")) && addImage(key, bundle.value(QStringLiteral("image/jpeg")))) ||
                (bundle.contains(QStringLiteral("png")) && addImage(key, bundle.value(QStringLiteral("png"))))) {
                // Qt's importer inserts an image only with alt text.
                markdown += QStringLiteral("![output](%1)\n\n").arg(key);
                continue;
            }
            QString text = joined(output.value(QStringLiteral("text")));
            if (text.isEmpty()) text = joined(bundle.value(QStringLiteral("text/plain")));
            if (!text.trimmed().isEmpty()) markdown += fence(QStringLiteral("output"), firstLines(text));
        }
        markdown += cellBreak + QStringLiteral("\n\n");
    }
    renderMarkdown(doc, markdown, images);
    return true;
}
