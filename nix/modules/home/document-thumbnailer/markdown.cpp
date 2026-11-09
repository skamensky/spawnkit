// Markdown in the GitHub dialect (tables, task lists, strikethrough, autolinks): Qt parses it
// with md4c into a QTextDocument, which is restyled here like GitHub's page, and
// KSyntaxHighlighting colours fenced code by its language.
#include "thumbnail.h"
#include <KSyntaxHighlighting/AbstractHighlighter>
#include <KSyntaxHighlighting/Definition>
#include <KSyntaxHighlighting/Format>
#include <KSyntaxHighlighting/Repository>
#include <KSyntaxHighlighting/State>
#include <KSyntaxHighlighting/Theme>
#include <QFontDatabase>
#include <QImage>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextLayout>
#include <QTextList>
#include <QTextTable>
#include <QUrl>

namespace KSH = KSyntaxHighlighting;

namespace {

// Collects the formats of one line of code as QTextLayout ranges.
class LineHighlighter : public KSH::AbstractHighlighter {
public:
    QList<QTextLayout::FormatRange> ranges;
    KSH::State highlight(const QString &text, const KSH::State &state) {
        ranges.clear();
        return highlightLine(text, state);
    }

protected:
    void applyFormat(int offset, int length, const KSH::Format &format) override {
        if (length == 0 || format.isDefaultTextStyle(theme())) return;
        QTextCharFormat f;
        if (format.hasTextColor(theme())) f.setForeground(format.textColor(theme()));
        if (format.isBold(theme())) f.setFontWeight(QFont::Bold);
        if (format.isItalic(theme())) f.setFontItalic(true);
        ranges.append({offset, length, f});
    }
};

bool fenced(const QTextBlock &b) { return b.isValid() && b.blockFormat().hasProperty(QTextFormat::BlockCodeFence); }
QString fenceLanguage(const QTextBlock &b) { return b.blockFormat().stringProperty(QTextFormat::BlockCodeLanguage); }
const QString outputLanguage = QStringLiteral("output");

} // namespace

void renderMarkdown(QTextDocument &doc, const QString &markdown, const QHash<QString, QImage> &images) {
    // The importer drops an image it cannot load, so the named ones are added first.
    for (auto it = images.begin(); it != images.end(); ++it) doc.addResource(QTextDocument::ImageResource, QUrl(it.key()), it.value());
    QTextCursor(&doc).insertMarkdown(markdown, QTextDocument::MarkdownDialectGitHub);

    // GitHub's code size, 85% of the text.
    QFont mono = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    mono.setPixelSize(qRound(doc.defaultFont().pixelSize() * 0.85));
    const qreal maxImageWidth = pageWidth - 2 * margin;
    QTextCursor cursor(&doc);
    for (QTextBlock block = doc.begin(); block.isValid(); block = block.next()) {
        QTextBlockFormat blockFormat = block.blockFormat();
        cursor.setPosition(block.position());
        // GitHub's spacing between blocks; Qt's Markdown import leaves none.
        if (block.text() == cellBreak) {
            blockFormat.setLineHeight(12, QTextBlockFormat::FixedHeight);
            blockFormat.setTopMargin(0);
            blockFormat.setBottomMargin(0);
        } else if (fenced(block)) {
            // Fenced code: a shaded block, and a cell's output plain beneath it.
            if (fenceLanguage(block) != outputLanguage) blockFormat.setBackground(codeBackground);
            blockFormat.setTopMargin(fenced(block.previous()) ? 0 : 4);
            blockFormat.setBottomMargin(fenced(block.next()) ? 0 : 14);
        } else if (blockFormat.headingLevel() > 0) {
            blockFormat.setTopMargin(block == doc.begin() ? 0 : 20);
            blockFormat.setBottomMargin(10);
        } else if (block.textList()) {
            blockFormat.setBottomMargin(4);
        } else if (!cursor.currentTable() && !blockFormat.hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)) {
            blockFormat.setBottomMargin(14);
        }
        cursor.setBlockFormat(blockFormat);
        const bool quote = blockFormat.intProperty(QTextFormat::BlockQuoteLevel) > 0;
        const bool output = fenced(block) && fenceLanguage(block) == outputLanguage;
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            QTextCharFormat format = fragment.charFormat();
            cursor.setPosition(fragment.position());
            cursor.setPosition(fragment.position() + fragment.length(), QTextCursor::KeepAnchor);
            if (format.isImageFormat()) {
                // Shrink an image wider than the page.
                QTextImageFormat image = format.toImageFormat();
                const QVariant resource = doc.resource(QTextDocument::ImageResource, QUrl(image.name()));
                const QSizeF natural = resource.value<QImage>().size();
                if (image.width() <= 0 && natural.width() > maxImageWidth) {
                    image.setWidth(maxImageWidth);
                    image.setHeight(natural.height() * maxImageWidth / natural.width());
                    cursor.setCharFormat(image);
                }
                continue;
            }
            if (format.fontFixedPitch() || fenced(block)) {
                // The importer sizes code in points, which would outrank a merged pixel size.
                format.clearProperty(QTextFormat::FontPointSize);
                format.setFontFamilies(mono.families());
                format.setProperty(QTextFormat::FontPixelSize, mono.pixelSize());
                if (!blockFormat.hasProperty(QTextFormat::BlockCodeFence)) format.setBackground(QColor(0xef, 0xf1, 0xf3));
            }
            if (format.isAnchor()) format.setForeground(link);
            else if (quote || output) format.setForeground(muted);
            cursor.setCharFormat(format);
        }
    }

    // Space below lists and tables, which end without a paragraph of their own.
    for (QTextBlock block = doc.begin(); block.isValid(); block = block.next()) {
        const QTextBlock next = block.next();
        if (block.textList() && (!next.isValid() || !next.textList())) {
            QTextBlockFormat f = block.blockFormat();
            f.setBottomMargin(14);
            cursor.setPosition(block.position());
            cursor.setBlockFormat(f);
        }
    }
    for (QTextFrame *frame : doc.rootFrame()->childFrames()) {
        if (auto *table = qobject_cast<QTextTable *>(frame)) {
            QTextTableFormat f = table->format();
            f.setBottomMargin(14);
            f.setCellPadding(6);
            f.setBorder(1);
            f.setBorderStyle(QTextFrameFormat::BorderStyle_Solid);
            f.setBorderBrush(rule);
            f.setBorderCollapse(true);
            table->setFormat(f);
        }
    }

    // Colour each fenced block's lines in its language. This runs after every edit above, as
    // an edit re-lays out its block and drops the layout's extra formats.
    KSH::Repository repository;
    LineHighlighter highlighter;
    highlighter.setTheme(repository.defaultTheme(KSH::Repository::LightTheme));
    KSH::State state;
    QString language;
    for (QTextBlock block = doc.begin(); block.isValid(); block = block.next()) {
        if (!fenced(block)) {
            language.clear();
            continue;
        }
        const QString blockLanguage = fenceLanguage(block);
        if (blockLanguage != language || !fenced(block.previous())) {
            language = blockLanguage;
            KSH::Definition definition;
            if (language != outputLanguage) {
                definition = repository.definitionForName(language);
                if (!definition.isValid()) definition = repository.definitionForFileName(QStringLiteral("x.") + language);
            }
            highlighter.setDefinition(definition);
            state = {};
        }
        if (!highlighter.definition().isValid()) continue;
        state = highlighter.highlight(block.text(), state);
        block.layout()->setFormats(highlighter.ranges);
    }
    doc.markContentsDirty(0, doc.characterCount());
}
