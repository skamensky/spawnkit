// Shared by the document renderers: each fills a QTextDocument laid out as a page, and
// main.cpp draws that page into the thumbnail.
#pragma once
#include <QByteArray>
#include <QColor>
#include <QHash>
#include <QImage>
#include <QString>
#include <QTextDocument>

// The page: GitHub's README width and colours, a portrait sheet at most.
constexpr qreal pageWidth = 820, margin = 32, maxHeight = pageWidth * 1.3;
inline const QColor ink(0x1f, 0x23, 0x28), muted(0x59, 0x63, 0x6e), codeBackground(0xf6, 0xf8, 0xfa),
    link(0x09, 0x69, 0xda), rule(0xd1, 0xd9, 0xe0);

// Fills doc with GitHub-flavoured Markdown: GitHub's spacing, tables and inline code, and
// fenced code highlighted in its language. A fence in the language "output" is plain
// monospace on the page's white, as a notebook prints a cell's result. A paragraph holding
// only cellBreak is a thin gap that keeps two fenced blocks apart. images supplies pictures
// that the Markdown names by key, as a notebook's outputs.
void renderMarkdown(QTextDocument &doc, const QString &markdown, const QHash<QString, QImage> &images = {});
inline const QString cellBreak = QStringLiteral("\u2063");

// Each fills doc from the file's bytes; false when they are not that format.
bool renderCsv(QTextDocument &doc, const QByteArray &data, char delimiter);
bool renderCalendar(QTextDocument &doc, const QByteArray &data);
bool renderNotebook(QTextDocument &doc, const QByteArray &data);
