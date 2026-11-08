// spawnkit-markdown-thumbnail SIZE INPUT OUTPUT: render INPUT's Markdown as a page, in the
// GitHub dialect (tables, task lists, strikethrough, autolinks), and write it as a PNG that
// fits in SIZE x SIZE pixels to OUTPUT. Qt parses the Markdown with md4c and lays it out with
// QTextDocument; KSyntaxHighlighting colours fenced code by its language.
#include <KSyntaxHighlighting/AbstractHighlighter>
#include <KSyntaxHighlighting/Definition>
#include <KSyntaxHighlighting/Format>
#include <KSyntaxHighlighting/Repository>
#include <KSyntaxHighlighting/State>
#include <KSyntaxHighlighting/Theme>
#include <QAbstractTextDocumentLayout>
#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextLayout>
#include <QTextList>
#include <QTextTable>
#include <QUrl>
#include <cstdio>

namespace KSH = KSyntaxHighlighting;

// The page: GitHub's README width and colours, a portrait sheet at most.
constexpr qreal pageWidth = 820, margin = 32, maxHeight = pageWidth * 1.3;
constexpr qint64 maxBytes = 256 * 1024; // the first page never needs more
const QColor ink(0x1f, 0x23, 0x28), muted(0x59, 0x63, 0x6e), codeBackground(0xf6, 0xf8, 0xfa),
    link(0x09, 0x69, 0xda);

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

int main(int argc, char **argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: spawnkit-markdown-thumbnail SIZE INPUT OUTPUT\n");
        return 2;
    }
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    const int size = QString::fromLocal8Bit(argv[1]).toInt();
    const QString input = QString::fromLocal8Bit(argv[2]);
    QFile file(input);
    if (size <= 0 || !file.open(QIODevice::ReadOnly)) {
        std::fprintf(stderr, "spawnkit-markdown-thumbnail: cannot read %s\n", argv[2]);
        return 1;
    }

    QTextDocument doc;
    QFont body(QStringLiteral("sans-serif"));
    body.setPixelSize(16);
    doc.setDefaultFont(body);
    doc.setDocumentMargin(margin);
    doc.setTextWidth(pageWidth);
    // Relative image paths resolve beside the file.
    doc.setBaseUrl(QUrl::fromLocalFile(QFileInfo(input).absolutePath() + QLatin1Char('/')));
    doc.setMarkdown(QString::fromUtf8(file.read(maxBytes)), QTextDocument::MarkdownDialectGitHub);

    const QFont mono = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    const qreal maxImageWidth = pageWidth - 2 * margin;
    QTextCursor cursor(&doc);
    for (QTextBlock block = doc.begin(); block.isValid(); block = block.next()) {
        QTextBlockFormat blockFormat = block.blockFormat();
        cursor.setPosition(block.position());
        // GitHub's spacing between blocks; Qt's Markdown import leaves none.
        const auto fenced = [](const QTextBlock &b) { return b.isValid() && b.blockFormat().hasProperty(QTextFormat::BlockCodeFence); };
        if (fenced(block)) {
            // Fenced code: a shaded block.
            blockFormat.setBackground(codeBackground);
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
            QTextCharFormat change;
            if (format.fontFixedPitch()) {
                change.setFont(mono, QTextCharFormat::FontPropertiesSpecifiedOnly);
                change.setFontFixedPitch(true);
                if (!blockFormat.hasProperty(QTextFormat::BlockCodeFence)) change.setBackground(QColor(0xef, 0xf1, 0xf3));
            }
            if (format.isAnchor()) change.setForeground(link);
            else if (quote) change.setForeground(muted);
            if (change.propertyCount()) cursor.mergeCharFormat(change);
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
            f.setBorderBrush(QColor(0xd1, 0xd9, 0xe0));
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
        const QTextBlockFormat blockFormat = block.blockFormat();
        if (!blockFormat.hasProperty(QTextFormat::BlockCodeFence)) {
            language.clear();
            continue;
        }
        const QString blockLanguage = blockFormat.stringProperty(QTextFormat::BlockCodeLanguage);
        if (blockLanguage != language || !block.previous().blockFormat().hasProperty(QTextFormat::BlockCodeFence)) {
            language = blockLanguage;
            KSH::Definition definition = repository.definitionForName(language);
            if (!definition.isValid()) definition = repository.definitionForFileName(QStringLiteral("x.") + language);
            highlighter.setDefinition(definition);
            state = {};
        }
        if (!highlighter.definition().isValid()) continue;
        state = highlighter.highlight(block.text(), state);
        block.layout()->setFormats(highlighter.ranges);
    }
    doc.markContentsDirty(0, doc.characterCount());

    const qreal height = qBound(pageWidth * 0.4, doc.size().height(), maxHeight);
    const qreal scale = size / qMax(pageWidth, height);
    QImage image(qRound(pageWidth * scale), qRound(height * scale), QImage::Format_RGB32);
    image.fill(Qt::white);
    QPainter painter(&image);
    painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing | QPainter::SmoothPixmapTransform);
    painter.scale(scale, scale);
    painter.setClipRect(QRectF(0, 0, pageWidth, height));
    QAbstractTextDocumentLayout::PaintContext context;
    context.palette.setColor(QPalette::Text, ink);
    context.palette.setColor(QPalette::Link, link);
    context.clip = QRectF(0, 0, pageWidth, height);
    doc.documentLayout()->draw(&painter, context);
    painter.end();
    if (!image.save(QString::fromLocal8Bit(argv[3]), "PNG")) {
        std::fprintf(stderr, "spawnkit-markdown-thumbnail: cannot write %s\n", argv[3]);
        return 1;
    }
    return 0;
}
