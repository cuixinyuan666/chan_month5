from .a_frontend_body import FRONTEND_BODY
from .a_frontend_ext import FRONTEND_EXT
from .a_frontend_script import FRONTEND_SCRIPT
from .a_frontend_style import FRONTEND_STYLE

HTML = (
    '<!DOCTYPE html>\n'
    '<html lang="zh-CN" data-theme="light">\n'
    '<head>\n'
    '  <meta charset="UTF-8" />\n'
    '  <meta name="viewport" content="width=device-width, initial-scale=1.0" />\n'
    '  <title>复盘</title>\n'
    '  <style>\n'
    + FRONTEND_STYLE
    + '\n  </style>\n\n'
    + '</head>\n'
    + FRONTEND_BODY
    + '<script>\n'
    + FRONTEND_SCRIPT
    + '\n'
    + FRONTEND_EXT
    + '\n</script>\n'
    + '</body>\n'
    + '</html>\n'
)
