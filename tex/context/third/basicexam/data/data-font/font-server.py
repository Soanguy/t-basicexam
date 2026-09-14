#!/usr/bin/env python3
import http.server
import json
import subprocess
import os
import threading
import time
import re
from urllib.parse import urlparse, parse_qs
from collections import defaultdict

PORT = 8081
DIRECTORY = os.path.dirname(os.path.abspath(__file__))
CACHE_FILE = os.path.join(DIRECTORY, '.font-cache.json')
FONT_CACHE = None
FONT_FAMILIES = None
CACHE_TIME = 0
CACHE_TTL = 300

def load_cache():
    global FONT_CACHE, FONT_FAMILIES, CACHE_TIME
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, 'r', encoding='utf-8') as f:
                data = json.load(f)
                FONT_CACHE = data.get('fonts', {})
                FONT_FAMILIES = data.get('families', {})
                CACHE_TIME = data.get('time', 0)
                print(f"Loaded {len(FONT_CACHE)} fonts, {len(FONT_FAMILIES)} families from cache")
        except:
            pass

def save_cache():
    try:
        with open(CACHE_FILE, 'w', encoding='utf-8') as f:
            json.dump({
                'fonts': FONT_CACHE, 
                'families': FONT_FAMILIES,
                'time': CACHE_TIME
            }, f, ensure_ascii=False)
    except:
        pass

def detect_font_style(name):
    name_lower = name.lower()
    style = {
        'weight': 'regular',
        'shape': 'normal',
        'width': 'normal'
    }
    
    if 'thin' in name_lower or 'hairline' in name_lower:
        style['weight'] = 'thin'
    elif 'extralight' in name_lower or 'ultralight' in name_lower:
        style['weight'] = 'extralight'
    elif 'light' in name_lower:
        style['weight'] = 'light'
    elif 'medium' in name_lower:
        style['weight'] = 'medium'
    elif 'semibold' in name_lower or 'demibold' in name_lower:
        style['weight'] = 'semibold'
    elif 'extrabold' in name_lower or 'ultrabold' in name_lower:
        style['weight'] = 'extrabold'
    elif 'bold' in name_lower:
        style['weight'] = 'bold'
    elif 'black' in name_lower or 'heavy' in name_lower:
        style['weight'] = 'black'
    
    if 'italic' in name_lower or 'it' in name_lower.split() or name_lower.endswith('it'):
        style['shape'] = 'italic'
    elif 'oblique' in name_lower or 'slanted' in name_lower:
        style['shape'] = 'oblique'
    
    if 'condensed' in name_lower or 'cond' in name_lower:
        style['width'] = 'condensed'
    elif 'extended' in name_lower or 'wide' in name_lower:
        style['width'] = 'extended'
    
    return style

def detect_font_type(name):
    name_lower = name.lower()
    
    if 'mono' in name_lower or 'code' in name_lower or 'console' in name_lower or 'terminal' in name_lower:
        return 'mono'
    if 'kai' in name_lower or 'script' in name_lower or 'hand' in name_lower or 'brush' in name_lower:
        return 'handw'
    if 'serif' in name_lower or 'song' in name_lower or 'mincho' in name_lower or 'ming' in name_lower or 'times' in name_lower:
        return 'serif'
    if 'sans' in name_lower or 'hei' in name_lower or 'gothic' in name_lower or 'arial' in name_lower or 'helvetica' in name_lower:
        return 'sans'
    
    return 'unknown'

def detect_language(name):
    name_lower = name.lower()
    
    if 'sc' in name_lower or 'simp' in name_lower or 'gb' in name_lower:
        return 'simplified-chinese'
    if 'tc' in name_lower or 'trad' in name_lower or 'big5' in name_lower:
        return 'traditional-chinese'
    if 'jp' in name_lower or 'japan' in name_lower or 'gothic' in name_lower or 'mincho' in name_lower:
        return 'japanese'
    if 'kr' in name_lower or 'korea' in name_lower:
        return 'korean'
    
    return 'unknown'

def extract_family_name(name):
    name_lower = name.lower()
    
    suffixes_ordered = [
        ('bolditalic', 'boldoblique'),
        ('extrabolditalic', 'extraboldoblique', 'ultrabolditalic'),
        ('semibolditalic', 'demibolditalic'),
        ('lightitalic', 'extralightitalic', 'ultralightitalic'),
        ('mediumitalic', 'thinitalic', 'blackitalic', 'heavyitalic'),
        ('italic', 'oblique', 'slanted'),
        ('extrabold', 'ultrabold'),
        ('semibold', 'demibold'),
        ('extralight', 'ultralight'),
        ('black', 'heavy'),
        ('thin', 'hairline'),
        ('light', 'medium', 'bold', 'regular', 'normal', 'roman', 'book'),
        ('condensed', 'extended', 'wide'),
    ]
    
    for suffix_group in suffixes_ordered:
        for suffix in suffix_group:
            if name_lower.endswith(suffix):
                base = name[:-len(suffix)]
                if base and len(base) >= 2:
                    return base.rstrip('-_ ')
    
    patterns = [
        r'^(.+?)[-_]?(?:bold[-_]?italic|bold[-_]?oblique)$',
        r'^(.+?)[-_]?(?:bold|italic|oblique|regular|light|medium|thin|black|heavy)$',
        r'^(.+?)[-_]?(?:extralight|ultralight|semibold|demibold|extrabold|ultrabold)$',
    ]
    
    for pattern in patterns:
        match = re.match(pattern, name, re.IGNORECASE)
        if match:
            return match.group(1).rstrip('-_ ')
    
    return name

def get_context_fonts():
    global FONT_CACHE, FONT_FAMILIES, CACHE_TIME
    
    current_time = time.time()
    if FONT_CACHE and FONT_FAMILIES and (current_time - CACHE_TIME) < CACHE_TTL:
        return FONT_CACHE, FONT_FAMILIES
    
    print("Fetching fonts from mtxrun...")
    try:
        result = subprocess.run(
            ['mtxrun', '--script', 'fonts', '--list', '--all'],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=os.path.expanduser('~')
        )
        fonts = {}
        families = defaultdict(lambda: {
            'styles': {},
            'types': set(),
            'languages': set(),
            'fonts': []
        })
        
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                parts = line.split()
                if len(parts) >= 1:
                    name = parts[0]
                    if name and not name.startswith('#') and not name.startswith('mtxrun'):
                        style = detect_font_style(name)
                        font_type = detect_font_type(name)
                        language = detect_language(name)
                        family_name = extract_family_name(name)
                        
                        fonts[name] = {
                            'familyname': family_name,
                            'filename': parts[1] if len(parts) > 1 else '',
                            'style': style,
                            'type': font_type,
                            'language': language
                        }
                        
                        family_key = family_name.lower()
                        families[family_key]['name'] = family_name
                        families[family_key]['styles'][name] = style
                        families[family_key]['types'].add(font_type)
                        families[family_key]['languages'].add(language)
                        families[family_key]['fonts'].append(name)
        
        for fk in families:
            families[fk]['types'] = list(families[fk]['types'])
            families[fk]['languages'] = list(families[fk]['languages'])
        
        if fonts:
            FONT_CACHE = fonts
            FONT_FAMILIES = dict(families)
            CACHE_TIME = current_time
            threading.Thread(target=save_cache, daemon=True).start()
            print(f"Found {len(fonts)} fonts in {len(families)} families")
        return fonts, FONT_FAMILIES
    except subprocess.TimeoutExpired:
        print("mtxrun timeout, using fc-list")
        return get_system_fonts_fc()
    except Exception as e:
        print(f"Error getting fonts: {e}")
        return get_system_fonts_fc()

def get_system_fonts_fc():
    try:
        result = subprocess.run(
            ['fc-list', ':', 'family', 'file', 'style'],
            capture_output=True,
            text=True,
            timeout=30
        )
        fonts = {}
        families = defaultdict(lambda: {'styles': {}, 'types': set(), 'languages': set(), 'fonts': []})
        
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                if ':' in line:
                    parts = line.split(':')
                    if len(parts) >= 2:
                        family = parts[0].strip().split(',')[0]
                        filepath = parts[1].strip()
                        name = os.path.basename(filepath).rsplit('.', 1)[0]
                        
                        style = detect_font_style(name)
                        font_type = detect_font_type(name)
                        language = detect_language(name)
                        
                        fonts[name.lower()] = {
                            'familyname': family,
                            'filename': filepath,
                            'style': style,
                            'type': font_type,
                            'language': language
                        }
                        
                        family_key = family.lower()
                        families[family_key]['name'] = family
                        families[family_key]['styles'][name.lower()] = style
                        families[family_key]['types'].add(font_type)
                        families[family_key]['languages'].add(language)
                        families[family_key]['fonts'].append(name.lower())
        
        for fk in families:
            families[fk]['types'] = list(families[fk]['types'])
            families[fk]['languages'] = list(families[fk]['languages'])
        
        return fonts, dict(families)
    except Exception as e:
        print(f"Error with fc-list: {e}")
        return {}, {}

def get_family_subfonts(family_key, fonts, families):
    if family_key not in families:
        return None
    
    family = families[family_key]
    subfonts = {
        'regular': None,
        'bold': None,
        'italic': None,
        'bolditalic': None,
        'light': None,
        'lightitalic': None,
        'extralight': None,
        'extralightitalic': None,
        'medium': None,
        'mediumitalic': None,
        'semibold': None,
        'semibolditalic': None,
        'extrabold': None,
        'extrabolditalic': None,
        'thin': None,
        'thinitalic': None,
        'black': None,
        'blackitalic': None,
        'all': []
    }
    
    for font_name in family.get('fonts', []):
        if font_name not in fonts:
            continue
        info = fonts[font_name]
        style = info.get('style', {})
        weight = style.get('weight', 'regular')
        shape = style.get('shape', 'normal')
        
        subfonts['all'].append({
            'name': font_name,
            'weight': weight,
            'shape': shape,
            'type': info.get('type', 'unknown')
        })
        
        is_italic = shape in ('italic', 'oblique')
        
        if weight == 'regular':
            if is_italic and not subfonts['italic']:
                subfonts['italic'] = font_name
            elif not is_italic and not subfonts['regular']:
                subfonts['regular'] = font_name
        elif weight == 'bold':
            if is_italic and not subfonts['bolditalic']:
                subfonts['bolditalic'] = font_name
            elif not is_italic and not subfonts['bold']:
                subfonts['bold'] = font_name
        elif weight == 'light':
            if is_italic and not subfonts['lightitalic']:
                subfonts['lightitalic'] = font_name
            elif not is_italic and not subfonts['light']:
                subfonts['light'] = font_name
        elif weight == 'extralight':
            if is_italic and not subfonts['extralightitalic']:
                subfonts['extralightitalic'] = font_name
            elif not is_italic and not subfonts['extralight']:
                subfonts['extralight'] = font_name
        elif weight == 'medium':
            if is_italic and not subfonts['mediumitalic']:
                subfonts['mediumitalic'] = font_name
            elif not is_italic and not subfonts['medium']:
                subfonts['medium'] = font_name
        elif weight == 'semibold':
            if is_italic and not subfonts['semibolditalic']:
                subfonts['semibolditalic'] = font_name
            elif not is_italic and not subfonts['semibold']:
                subfonts['semibold'] = font_name
        elif weight == 'extrabold':
            if is_italic and not subfonts['extrabolditalic']:
                subfonts['extrabolditalic'] = font_name
            elif not is_italic and not subfonts['extrabold']:
                subfonts['extrabold'] = font_name
        elif weight == 'thin':
            if is_italic and not subfonts['thinitalic']:
                subfonts['thinitalic'] = font_name
            elif not is_italic and not subfonts['thin']:
                subfonts['thin'] = font_name
        elif weight == 'black':
            if is_italic and not subfonts['blackitalic']:
                subfonts['blackitalic'] = font_name
            elif not is_italic and not subfonts['black']:
                subfonts['black'] = font_name
    
    return subfonts

class FontServerHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)
    
    def log_message(self, format, *args):
        msg = format % args if args else format
        if '/@vite/' not in str(msg):
            super().log_message(format, *args)
    
    def do_HEAD(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith('/api/') or parsed.path == '/fonts.json':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
        else:
            super().do_HEAD()
    
    def do_GET(self):
        parsed = urlparse(self.path)
        
        if parsed.path == '/fonts.json':
            self._send_json({'fonts': get_context_fonts()[0]})
            
        elif parsed.path == '/api/fonts':
            fonts, families = get_context_fonts()
            self._send_json({'fonts': fonts, 'families': families})
            
        elif parsed.path == '/api/families':
            fonts, families = get_context_fonts()
            self._send_json(families)
            
        elif parsed.path == '/api/family':
            query = parse_qs(parsed.query).get('name', [''])[0].lower()
            fonts, families = get_context_fonts()
            if query in families:
                family = families[query]
                subfonts = get_family_subfonts(query, fonts, families)
                self._send_json({'family': family, 'subfonts': subfonts})
            else:
                self._send_json({'error': 'Family not found'}, 404)
                
        elif parsed.path == '/api/subfonts':
            query = parse_qs(parsed.query).get('name', [''])[0].lower()
            fonts, families = get_context_fonts()
            if query in families:
                subfonts = get_family_subfonts(query, fonts, families)
                self._send_json(subfonts)
            else:
                self._send_json({'error': 'Family not found'}, 404)
                
        elif parsed.path == '/api/search':
            query = parse_qs(parsed.query).get('q', [''])[0].lower()
            ftype = parse_qs(parsed.query).get('type', [''])[0]
            lang = parse_qs(parsed.query).get('lang', [''])[0]
            
            fonts, families = get_context_fonts()
            filtered = {}
            for k, v in fonts.items():
                if query and query not in k.lower() and query not in v.get('familyname', '').lower():
                    continue
                if ftype and v.get('type') != ftype:
                    continue
                if lang and v.get('language') != lang:
                    continue
                filtered[k] = v
            self._send_json({'fonts': filtered})
            
        elif parsed.path == '/api/categorized':
            fonts, families = get_context_fonts()
            categorized = {
                'by_type': {'serif': {}, 'sans': {}, 'mono': {}, 'handw': {}, 'unknown': {}},
                'by_language': {},
                'by_family': {},
                'families': families
            }
            
            for name, info in fonts.items():
                ftype = info.get('type', 'unknown')
                if ftype not in categorized['by_type']:
                    categorized['by_type'][ftype] = {}
                categorized['by_type'][ftype][name] = info
                
                lang = info.get('language', 'unknown')
                if lang not in categorized['by_language']:
                    categorized['by_language'][lang] = {}
                categorized['by_language'][lang][name] = info
                
                family_key = info.get('familyname', '').lower()
                if family_key:
                    if family_key not in categorized['by_family']:
                        categorized['by_family'][family_key] = {
                            'name': info.get('familyname'),
                            'fonts': [],
                            'types': set(),
                            'languages': set()
                        }
                    categorized['by_family'][family_key]['fonts'].append(name)
                    categorized['by_family'][family_key]['types'].add(ftype)
                    categorized['by_family'][family_key]['languages'].add(lang)
            
            for fk in categorized['by_family']:
                categorized['by_family'][fk]['types'] = list(categorized['by_family'][fk]['types'])
                categorized['by_family'][fk]['languages'] = list(categorized['by_family'][fk]['languages'])
            
            self._send_json(categorized)
            
        elif parsed.path == '/api/refresh':
            global FONT_CACHE, FONT_FAMILIES, CACHE_TIME
            FONT_CACHE = None
            FONT_FAMILIES = None
            CACHE_TIME = 0
            fonts, families = get_context_fonts()
            self._send_json({'status': 'ok', 'fonts': len(fonts), 'families': len(families)})
            
        else:
            super().do_GET()
    
    def _send_json(self, data, code=200):
        self.send_response(code)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))
    
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

if __name__ == '__main__':
    print(f"Starting font server on port {PORT}...")
    print(f"Serving files from: {DIRECTORY}")
    print(f"Access the generator at: http://localhost:{PORT}/font-config-generator.html")
    
    load_cache()
    
    server = http.server.HTTPServer(('0.0.0.0', PORT), FontServerHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
