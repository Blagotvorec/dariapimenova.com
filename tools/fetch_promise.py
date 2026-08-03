#!/usr/bin/env python3
"""Забирает из телеграм-канала последнее «Обещание на неделю» и кладёт в promise.json.

Читается публичная превью-страница канала (https://t.me/s/<канал>) — истории
канала Bot API не отдаёт вообще, он видит только новые посты и только если бот
сделан админом. Поэтому токен здесь не нужен и нигде не хранится.

Запуск: python3 tools/fetch_promise.py [канал] [файл]
"""

import html
import json
import os
import re
import sys
import urllib.request

CHANNEL = sys.argv[1] if len(sys.argv) > 1 else "genius_meridian"
OUT = sys.argv[2] if len(sys.argv) > 2 else "promise.json"

# заголовок поста, по которому узнаём обещание
HEADING = re.compile(r"^\s*[^\wА-Яа-яЁё]*обещани[ея]\s+на\s+недел[юи]\s*[:\-—.!]*\s*", re.I)
PAGES = 5  # сколько страниц истории просматриваем вглубь

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept-Language": "ru,en;q=0.9"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def strip_tags(fragment):
    text = re.sub(r"<br\s*/?>", "\n", fragment)
    text = re.sub(r"</p\s*>", "\n\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).strip()


def parse_page(page):
    """Возвращает список постов страницы: (id, текст, дата)."""
    posts = []
    for chunk in page.split('<div class="tgme_widget_message ')[1:]:
        m_id = re.search(r'data-post="[^/]+/(\d+)"', chunk)
        m_text = re.search(r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>',
                           chunk, re.S)
        m_date = re.search(r'<time datetime="([^"]+)"', chunk)
        if not (m_id and m_text):
            continue
        posts.append((int(m_id.group(1)),
                      strip_tags(m_text.group(1)),
                      m_date.group(1) if m_date else ""))
    return posts


def find_promise():
    before = ""
    seen_oldest = None
    for _ in range(PAGES):
        url = f"https://t.me/s/{CHANNEL}" + (f"?before={before}" if before else "")
        posts = parse_page(get(url))
        if not posts:
            break
        for post_id, text, date in sorted(posts, key=lambda p: -p[0]):
            if HEADING.search(text):
                body = HEADING.sub("", text, count=1).strip()
                return {
                    "found": True,
                    "id": post_id,
                    "text": body or text.strip(),
                    "date": date,
                    "url": f"https://t.me/{CHANNEL}/{post_id}",
                }
        oldest = min(p[0] for p in posts)
        if oldest == seen_oldest:
            break
        seen_oldest = before = oldest
    return {"found": False}


def main():
    try:
        promise = find_promise()
    except Exception as exc:                      # сеть недоступна — не портим файл
        print("не удалось прочитать канал:", exc, file=sys.stderr)
        return 1

    promise["channel"] = CHANNEL
    promise["channel_url"] = f"https://t.me/{CHANNEL}"

    old = None
    if os.path.exists(OUT):
        try:
            old = json.load(open(OUT, encoding="utf-8"))
        except Exception:
            old = None

    # обещаний ещё нет — оставляем то, что уже показывали
    if not promise["found"] and old and old.get("found"):
        print("новых обещаний нет, оставляем прежнее")
        return 0

    if old and old.get("id") == promise.get("id") and old.get("found") == promise["found"]:
        print("без изменений")
        return 0

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(promise, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("обновлено:", promise.get("id"), (promise.get("text") or "")[:60])
    return 0


if __name__ == "__main__":
    sys.exit(main())
