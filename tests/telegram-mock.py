#!/usr/bin/env python3
"""Заглушка Telegram Bot API для тестов amnezia-autoupdate.

    python3 tests/telegram-mock.py ПАПКА ТОКЕН ЧАТЫ

ЧАТЫ: id чатов через запятую, в которые бот может писать (в остальные: chat not found).
Порт заглушка пишет в ПАПКА/port, отправленные сообщения в ПАПКА/sent.jsonl,
все вызовы Bot API в ПАПКА/calls.jsonl.

Входящее сообщение для бота: POST /test/message с chat_id, text и age (сколько секунд
назад оно отправлено). POST /test/webhook?on=1 включает webhook (getUpdates тогда даёт 409).

getUpdates ведёт себя как у Telegram: offset > 0 подтверждает (удаляет) сообщения до него,
offset < 0 оставляет только последние, запрос с timeout ждёт новых сообщений, а новый
getUpdates обрывает прежний, ещё ждущий, ошибкой 409.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DIR, TOKEN, CHATS = sys.argv[1], sys.argv[2], set(sys.argv[3].split(','))
os.makedirs(DIR, exist_ok=True)

cond = threading.Condition()
files_lock = threading.Lock()
st = {'updates': [], 'next_update': 1000, 'next_msg': 1, 'gen': 0, 'webhook': False}

CONFLICT = 'Conflict: terminated by other getUpdates request; make sure that only one bot instance is running'
WEBHOOK = "Conflict: can't use getUpdates method while webhook is active; use deleteWebhook to delete the webhook first"


def record(name, obj):
    with files_lock, open(os.path.join(DIR, name), 'a', encoding='utf-8') as f:
        f.write(json.dumps(obj, ensure_ascii=False) + '\n')


def error(code, description):
    return code, {'ok': False, 'error_code': code, 'description': description}


def get_updates(p):
    offset = int(p['offset']) if p.get('offset') else None
    limit = int(p.get('limit') or 100)
    timeout = float(p.get('timeout') or 0)
    with cond:
        st['gen'] += 1
        me = st['gen']
        cond.notify_all()
        if st['webhook']:
            return error(409, WEBHOOK)
        deadline = time.time() + timeout
        while True:
            if offset is not None and offset > 0:
                st['updates'] = [u for u in st['updates'] if u['update_id'] >= offset]
            elif offset is not None and offset < 0:
                st['updates'] = st['updates'][offset:]
            result = st['updates'][:limit]
            left = deadline - time.time()
            if result or left <= 0:
                return 200, {'ok': True, 'result': result}
            cond.wait(left)
            if st['gen'] != me:
                return error(409, CONFLICT)


def add_message(p):
    chat = int(p['chat_id'])
    with cond:
        update = {
            'update_id': st['next_update'],
            'message': {
                'message_id': st['next_msg'],
                'from': {'id': abs(chat), 'is_bot': False, 'first_name': 'Test'},
                'chat': {'id': chat, 'type': 'private' if chat > 0 else 'group'},
                'date': int(time.time() - float(p.get('age') or 0)),
                'text': p.get('text', ''),
            },
        }
        st['next_update'] += 1
        st['next_msg'] += 1
        st['updates'].append(update)
        cond.notify_all()
    return 200, {'ok': True, 'update_id': update['update_id']}


def api(method, p):
    if method == 'getMe':
        return 200, {'ok': True, 'result': {'id': int(TOKEN.split(':')[0]), 'is_bot': True,
                                             'first_name': 'Test', 'username': 'aau_test_bot'}}
    if method == 'getUpdates':
        return get_updates(p)
    if method == 'sendMessage':
        chat, text = p.get('chat_id', ''), p.get('text', '')
        if chat not in CHATS:
            return error(400, 'Bad Request: chat not found')
        if not text.strip():
            return error(400, 'Bad Request: message text is empty')
        if len(text.encode('utf-16-le')) // 2 > 4096:
            return error(400, 'Bad Request: message is too long')
        record('sent.jsonl', {'chat_id': chat, 'text': text, 't': time.time()})
        with cond:
            st['next_msg'] += 1
        return 200, {'ok': True, 'result': {'message_id': st['next_msg'], 'text': text}}
    if method == 'setMyCommands':
        json.loads(p.get('commands', ''))
        return 200, {'ok': True, 'result': True}
    return error(404, 'Not Found')


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def params(self):
        url = urlparse(self.path)
        p = {k: v[-1] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            body = self.rfile.read(n).decode('utf-8')
            if 'json' in (self.headers.get('Content-Type') or ''):
                p.update({k: v if isinstance(v, str) else json.dumps(v) for k, v in json.loads(body).items()})
            else:
                p.update({k: v[-1] for k, v in parse_qs(body, keep_blank_values=True).items()})
        return url.path, p

    def reply(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def route(self):
        path, p = self.params()
        if path == '/test/message':
            return self.reply(*add_message(p))
        if path == '/test/webhook':
            st['webhook'] = p.get('on') == '1'
            return self.reply(200, {'ok': True})
        parts = path.split('/')
        if len(parts) != 3 or not parts[1].startswith('bot'):
            return self.reply(*error(404, 'Not Found'))
        token, method = parts[1][3:], parts[2]
        record('calls.jsonl', {'method': method, 'params': p, 'token_ok': token == TOKEN, 't': time.time()})
        if token != TOKEN:
            return self.reply(*error(401, 'Unauthorized'))
        try:
            return self.reply(*api(method, p))
        except (ValueError, KeyError) as e:
            return self.reply(*error(400, f'Bad Request: {e}'))

    do_GET = route
    do_POST = route


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
with open(os.path.join(DIR, 'port.tmp'), 'w') as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, 'port.tmp'), os.path.join(DIR, 'port'))
server.serve_forever()
