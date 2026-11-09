// spawnkit-document-thumbnail KIND SIZE INPUT OUTPUT: draw INPUT as a page and write it as a
// PNG that fits in SIZE x SIZE pixels to OUTPUT. KIND is markdown, csv, tsv, calendar or
// notebook; each has its own freedesktop .thumbnailer entry.
#include "thumbnail.h"
#include <QAbstractTextDocumentLayout>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QPainter>
#include <QUrl>
#include <cstdio>

int main(int argc, char **argv) {
    if (argc != 5) {
        std::fprintf(stderr, "usage: spawnkit-document-thumbnail markdown|csv|tsv|calendar|notebook SIZE INPUT OUTPUT\n");
        return 2;
    }
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    const QByteArray kind = argv[1];
    const int size = QString::fromLocal8Bit(argv[2]).toInt();
    const QString input = QString::fromLocal8Bit(argv[3]);
    QFile file(input);
    if (size <= 0 || !file.open(QIODevice::ReadOnly)) {
        std::fprintf(stderr, "spawnkit-document-thumbnail: cannot read %s\n", argv[3]);
        return 1;
    }
    // A notebook is JSON, read whole; for the rest the first page never needs more.
    const QByteArray data = file.read(kind == "notebook" ? 64 << 20 : 256 << 10);

    QTextDocument doc;
    QFont body(QStringLiteral("sans-serif"));
    body.setPixelSize(16);
    doc.setDefaultFont(body);
    doc.setDocumentMargin(margin);
    doc.setTextWidth(pageWidth);
    // Relative image paths resolve beside the file.
    doc.setBaseUrl(QUrl::fromLocalFile(QFileInfo(input).absolutePath() + QLatin1Char('/')));
    bool rendered = false;
    if (kind == "markdown") rendered = (renderMarkdown(doc, QString::fromUtf8(data)), true);
    else if (kind == "csv") rendered = renderCsv(doc, data, 0);
    else if (kind == "tsv") rendered = renderCsv(doc, data, '\t');
    else if (kind == "calendar") rendered = renderCalendar(doc, data);
    else if (kind == "notebook") rendered = renderNotebook(doc, data);
    else {
        std::fprintf(stderr, "spawnkit-document-thumbnail: unknown kind %s\n", argv[1]);
        return 2;
    }
    if (!rendered) {
        std::fprintf(stderr, "spawnkit-document-thumbnail: %s is not a readable %s file\n", argv[3], argv[1]);
        return 1;
    }

    // A renderer may narrow the page to its content, as for a table of a few columns.
    const qreal width = doc.textWidth();
    const qreal height = qBound(width * 0.4, doc.size().height(), maxHeight);
    const qreal scale = size / qMax(width, height);
    QImage image(qRound(width * scale), qRound(height * scale), QImage::Format_RGB32);
    image.fill(Qt::white);
    QPainter painter(&image);
    painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing | QPainter::SmoothPixmapTransform);
    painter.scale(scale, scale);
    painter.setClipRect(QRectF(0, 0, width, height));
    QAbstractTextDocumentLayout::PaintContext context;
    context.palette.setColor(QPalette::Text, ink);
    context.palette.setColor(QPalette::Link, link);
    context.clip = QRectF(0, 0, width, height);
    doc.documentLayout()->draw(&painter, context);
    painter.end();
    if (!image.save(QString::fromLocal8Bit(argv[4]), "PNG")) {
        std::fprintf(stderr, "spawnkit-document-thumbnail: cannot write %s\n", argv[4]);
        return 1;
    }
    return 0;
}
