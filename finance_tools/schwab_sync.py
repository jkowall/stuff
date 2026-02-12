import csv
import argparse
import os
import sys
from datetime import datetime
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
import re
import json

HISTORY_FILE = 'news_history.json'

def load_history(filepath):
    """Loads the news history from a JSON file."""
    if os.path.exists(filepath):
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                return set(json.load(f))
        except:
            return set()
    return set()

def save_history(filepath, history):
    """Saves the news history to a JSON file."""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(list(history), f)
    except Exception as e:
        print(f"Warning: Could not save news history: {e}")

def parse_schwab_csv(filepath):
    """
    Parses the Schwab export CSV using standard 'csv' library.
    Returns a list of dictionaries with keys: Symbol, Quantity, Cost, Date.
    """
    holdings = []
    try:
        with open(filepath, 'r', encoding='utf-8-sig') as f:
            lines = f.readlines()

        # Find header row
        header_row_index = -1
        for i, line in enumerate(lines):
            if '"Symbol"' in line or 'Symbol' in line:
                header_row_index = i
                break
        
        if header_row_index == -1:
            print("Error: 'Symbol' column not found in CSV.")
            return []

        # Parse CSV from header row onwards
        reader = csv.reader(lines[header_row_index:])
        header = next(reader)
        
        # Clean header mapping
        header_map = {col.strip().replace('"', ''): i for i, col in enumerate(header)}
        
        if 'Symbol' not in header_map:
            print("Error: 'Symbol' column missing in header.")
            return []
            
        # Find other columns
        qty_col = header_map.get('Quantity')
        cost_col_name = None
        for col in header_map:
            if 'Cost Basis' in col:
                cost_col_name = col
                break
        
        cost_col = header_map.get(cost_col_name) if cost_col_name else None

        for row in reader:
            if not row: continue
            
            # Safe access
            try:
                symbol = row[header_map['Symbol']].strip().replace('"', '')
            except IndexError:
                continue

            # Skip invalid rows
            if not symbol or 'Cash &' in symbol or 'Account Total' in symbol:
                continue
                
            # Quantity
            qty = 0.0
            if qty_col is not None and len(row) > qty_col:
                try:
                    qty_str = row[qty_col].replace(',', '').replace('"', '')
                    qty = float(qty_str)
                except ValueError:
                    qty = 0.0
            
            # Cost
            total_cost = 0.0
            if cost_col is not None and len(row) > cost_col:
                try:
                    cost_str = row[cost_col].replace('$', '').replace(',', '').replace('"', '')
                    if cost_str and cost_str != 'N/A':
                        total_cost = float(cost_str)
                except ValueError:
                    total_cost = 0.0
            
            # Calculate Unit Cost (approximate)
            unit_cost = 0.0
            if qty != 0:
                unit_cost = total_cost / qty
                
            holdings.append({
                'Symbol': symbol,
                'Quantity': qty,
                'Cost': unit_cost,
                'Date': datetime.today().strftime('%Y-%m-%d')
            })
            
        return holdings

    except Exception as e:
        print(f"Error parsing CSV: {e}")
        return []

def write_seeking_alpha_csv(holdings, output_path):
    """
    Writes the holdings to a CSV compatible with Seeking Alpha.
    """
    try:
        with open(output_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['Symbol', 'Quantity', 'Cost', 'Date'])
            for h in holdings:
                writer.writerow([h['Symbol'], h['Quantity'], f"{h['Cost']:.2f}", h['Date']])
        print(f"Successfully created Seeking Alpha import file at: {output_path}")
    except Exception as e:
        print(f"Error writing output CSV: {e}")

def fetch_news(ticker):
    """
    Fetches news from Google News RSS using standard library.
    Returns ALL available items from the feed.
    """
    clean_ticker = ticker.strip().upper()
    rss_url = f"https://news.google.com/rss/search?q=STOCK:{clean_ticker}"
    
    try:
        # Use User-Agent to avoid 403
        req = urllib.request.Request(
            rss_url, 
            data=None, 
            headers={
                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36'
            }
        )
        
        with urllib.request.urlopen(req, timeout=10) as response:
            xml_data = response.read()
            
        root = ET.fromstring(xml_data)
        
        # Parse items
        news_items = []
        # RSS 2.0: channel -> item
        channel = root.find('channel')
        if channel is None: return []
        
        # Removed slice limit to get all stories
        for item in channel.findall('item'):
            title = item.find('title').text if item.find('title') is not None else 'No Title'
            link = item.find('link').text if item.find('link') is not None else '#'
            pubDate = item.find('pubDate').text if item.find('pubDate') is not None else ''
            guid = item.find('guid').text if item.find('guid') is not None else link # Use GUID or Link as ID
            
            news_items.append({
                'title': title,
                'link': link,
                'published': pubDate,
                'id': guid
            })
            
        return news_items
        
    except Exception as e:
        # print(f"Error fetching news for {ticker}: {e}") # Suppress noise
        return []

def generate_news_report(holdings, output_path, history_file):
    """
    Generates an HTML report.
    Filters out stories present in history_file.
    Updates history_file with new stories.
    """
    
    # Load history
    history = load_history(history_file)
    original_history_size = len(history)
    
    html_content = """
    <html>
    <head>
        <title>Portfolio News Report</title>
        <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; padding: 20px; line-height: 1.6; color: #333; }
            h1 { color: #2c3e50; border-bottom: 2px solid #eee; padding-bottom: 10px; }
            .ticker-section { margin-bottom: 40px; }
            .ticker-header { display: flex; align-items: baseline; border-bottom: 1px solid #eee; margin-bottom: 15px; padding-bottom: 5px; }
            .ticker-symbol { font-size: 1.5em; font-weight: bold; color: #2980b9; margin-right: 10px; }
            .news-list { list-style: none; padding: 0; }
            .news-item { margin-bottom: 15px; padding: 10px; background: #f9f9f9; border-radius: 5px; }
            .news-title { font-weight: 600; margin-bottom: 5px; }
            .news-title a { text-decoration: none; color: #2c3e50; }
            .news-title a:hover { color: #3498db; }
            .news-date { color: #7f8c8d; font-size: 0.85em; }
            .no-news { color: #777; font-style: italic; }
        </style>
    </head>
    <body>
        <h1>Portfolio News Report</h1>
        <p style="color: #666;">Generated on: """ + datetime.now().strftime("%Y-%m-%d %H:%M:%S") + """</p>
    """
    
    # Get unique symbols
    symbols = sorted(list(set(h['Symbol'] for h in holdings)))
    
    print(f"Fetching news for {len(symbols)} symbols...")
    
    count = 0
    total_new_stories = 0
    
    for symbol in symbols:
        # Skip weird symbols
        if not symbol.replace('.','').isalpha():
            continue
            
        news_items = fetch_news(symbol)
        count += 1
        if count % 5 == 0: print(f"Processing... ({count}/{len(symbols)})")
        
        # Filter new items
        new_items = []
        for item in news_items:
            # Use GUID or Link as unique identifier
            item_id = item.get('id', item['link'])
            if item_id not in history:
                new_items.append(item)
                history.add(item_id)
        
        if new_items:
            total_new_stories += len(new_items)
            html_content += f'<div class="ticker-section"><div class="ticker-header"><span class="ticker-symbol">{symbol}</span></div>'
            html_content += '<ul class="news-list">'
            for item in new_items:
                html_content += f"""
                <li class="news-item">
                    <div class="news-title"><a href="{item['link']}" target="_blank">{item['title']}</a></div>
                    <div class="news-date">{item['published']}</div>
                </li>
                """
            html_content += "</ul></div>"
        else:
             html_content += f'<div class="ticker-section"><div class="ticker-header"><span class="ticker-symbol">{symbol}</span></div><p class="no-news">No new stories found.</p></div>'

    html_content += "</body></html>"
    
    # Save history if changed
    if len(history) > original_history_size:
        save_history(history_file, history)
        print(f"History updated. added {len(history) - original_history_size} new stories.")
    else:
        print("No new stories to add to history.")
    
    try:
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(html_content)
        print(f"Successfully created News Report at: {output_path}")
    except Exception as e:
        print(f"Error writing news report: {e}")

def load_config(config_path):
    """Loads configuration from a JSON file."""
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading config file: {e}")
        return {}

def main():
    parser = argparse.ArgumentParser(description="Sync Schwab CSV to Seeking Alpha & Fetch News")
    parser.add_argument('input_csv', help="Path to the Schwab export CSV file")
    
    # Config argument
    parser.add_argument('--config', help="Path to a JSON configuration file")
    
    parser.add_argument('--output_csv', default='seeking_alpha_import.csv', help="Path for the output CSV")
    parser.add_argument('--news_report', default='portfolio_news.html', help="Path for the news report HTML")
    parser.add_argument('--history_file', default='news_history.json', help="Path to the news history file")
    parser.add_argument('--skip-news', action='store_true', help="Skip fetching news")
    parser.add_argument('--ignore-history', action='store_true', help="Ignore history and show all news")
    
    # Email arguments
    parser.add_argument('--email_to', help="Destination email for the report")
    parser.add_argument('--email_from', help="Sender email address")
    parser.add_argument('--smtp_server', default='smtp.gmail.com', help="SMTP server (default: smtp.gmail.com)")
    parser.add_argument('--smtp_port', default='587', help="SMTP port (default: 587)")
    parser.add_argument('--smtp_user', help="SMTP username (usually email address)")
    parser.add_argument('--smtp_password', help="SMTP password (or app password)")
    
    args = parser.parse_args()
    
    # Load config if specified
    config = {}
    if args.config:
        config_path = os.path.abspath(args.config)
        if os.path.exists(config_path):
            config = load_config(config_path)
        else:
            print(f"Warning: Config file '{config_path}' not found.")

    # specialized helper to get value from args (highest priority), then config, then default
    def get_arg(arg_name, default=None):
        # 1. Check if arg was explicitly provided on CLI (not None and not default if we can tell, 
        # but argparse puts defaults in namespace so hard to tell if user provided it or it's default 
        # unless we check sys.argv or use default=None in add_argument)
        # Actually, argparse is tricky with defaults vs config files.
        # Best practice: set argparse defaults to None, then fill in from config, then defaults.
        # But we already set defaults.
        # Let's check if the value in args matches the default logic.
        # Simpler approach:
        # If args.config is set, we overwrite args values with config values IF config values exist 
        # AND (args value is None OR args value is its default).
        # But determining "is its default" is hard.
        # BETTER STRATEGY: 
        # 1. Update the 'args' namespace with config values ONLY IF the arg value is currently None?
        #    No, that means CLI args (starting as None) wouldn't work if they weren't passed.
        # 2. Standard pattern: Defaults < Config File < Environment Vars < CLI Args
        #    To do this with argparse, we usually parse args with defaults=None, then merge.
        #    Refactoring argparse definitions slightly to defaults=None would be cleaner.
        pass

    # Let's adjust argparse to use None as defaults where appropriate so we can layer config.
    # Refactoring argparse setup inside main...
    
    # ... Wait, I can't easily refactor the whole block with replace_file_content if I'm only replacing a chunk.
    # I will stick to the current block replacement and rewrite the argparse part.
    pass
    
    # Redefining parser to handle defaults manually
    parser = argparse.ArgumentParser(description="Sync Schwab CSV to Seeking Alpha & Fetch News")
    parser.add_argument('input_csv', help="Path to the Schwab export CSV file")
    parser.add_argument('--config', help="Path to a JSON configuration file")
    
    # Use defaults=None for optional args so we can detect if user provided them
    parser.add_argument('--output_csv', help="Path for the output CSV")
    parser.add_argument('--news_report', help="Path for the news report HTML")
    parser.add_argument('--history_file', help="Path to the news history file")
    parser.add_argument('--skip-news', action='store_true', help="Skip fetching news") # Boolean, default False
    parser.add_argument('--ignore-history', action='store_true', help="Ignore history and show all news") # Boolean

    parser.add_argument('--email_to', help="Destination email for the report")
    parser.add_argument('--email_from', help="Sender email address")
    parser.add_argument('--smtp_server', help="SMTP server (default: smtp.gmail.com)")
    parser.add_argument('--smtp_port', help="SMTP port (default: 587)")
    parser.add_argument('--smtp_user', help="SMTP username")
    parser.add_argument('--smtp_password', help="SMTP password")

    args = parser.parse_args()

    # Load config
    config = {}
    if args.config:
        config_path = os.path.abspath(args.config)
        if os.path.exists(config_path):
            config = load_config(config_path)
            print(f"Loaded config from {config_path}")
        else:
            print(f"Warning: Config file '{config_path}' not found.")

    # Helper to resolve value: Args > Config > Default
    def resolve(arg_val, config_key, default_val):
        if arg_val is not None:
            return arg_val
        if config_key in config and config[config_key]:
            return config[config_key]
        return default_val

    # Resolve values
    output_csv = resolve(args.output_csv, 'output_csv', 'seeking_alpha_import.csv')
    news_report = resolve(args.news_report, 'news_report', 'portfolio_news.html')
    history_file = resolve(args.history_file, 'history_file', 'news_history.json')
    
    # Booleans are tricky bc argparse store_true gives False, not None.
    # If key exists in config, use it, unless CLI forced it True. 
    # But usually flags are "overrides". If config says "skip_news": true, and CLI says nothing (False), 
    # should we skip? Yes.
    # If config says "skip_news": false, and CLI says --skip-news (True), should we skip? Yes.
    # Logic: Config OR Args
    skip_news = args.skip_news or config.get('skip_news', False)
    ignore_history = args.ignore_history or config.get('ignore_history', False)

    email_to = resolve(args.email_to, 'email_to', None)
    email_from = resolve(args.email_from, 'email_from', None)
    smtp_server = resolve(args.smtp_server, 'smtp_server', 'smtp.gmail.com')
    smtp_port = resolve(args.smtp_port, 'smtp_port', '587')
    smtp_user = resolve(args.smtp_user, 'smtp_user', None)
    smtp_password = resolve(args.smtp_password, 'smtp_password', None)
    
    # Assign resolved values back to args conventions for rest of script
    args.output_csv = output_csv
    args.news_report = news_report
    args.history_file = history_file
    args.skip_news = skip_news
    args.ignore_history = ignore_history
    args.email_to = email_to
    args.email_from = email_from
    args.smtp_server = smtp_server
    args.smtp_port = smtp_port
    args.smtp_user = smtp_user
    args.smtp_password = smtp_password
    
    input_path = os.path.abspath(args.input_csv)
    
    # Resolve paths relative to the script directory if they are not absolute
    # This ensures files are kept with the tool by default, rather than cluttering CWD
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    def resolve_path(path):
        if os.path.isabs(path):
            return path
        return os.path.join(script_dir, path)

    output_csv = resolve_path(args.output_csv)
    news_report = resolve_path(args.news_report)
    history_path = resolve_path(args.history_file)
    
    # Update args for use in functions
    args.output_csv = output_csv
    args.news_report = news_report
    # History path logic was partly here, but now unified above
    
    if args.ignore_history:
        # If ignoring history, we act as if we have no history, but we don't want to overwrite the real history with a partial one.
        # Actually, simpler logic: duplicate the logic of load_history but return empty set if ignore_history is True.
        # But we still want to SAVE history? Or not? "Ignore history" usually means "show me everything".
        # If we show everything, we probably should mark them as seen?
        # Let's assume ignore_history means: read nothing, but write everything seen to history.
        pass

    if not os.path.exists(input_path):
        print(f"Error: Input file '{input_path}' not found.")
        sys.exit(1)
        
    print(f"Processing {input_path}...")
    holdings = parse_schwab_csv(input_path)
    
    if holdings:
        write_seeking_alpha_csv(holdings, args.output_csv)
        
        if not args.skip_news:
            # Determine history file to use
            target_history_file = history_path
            
            # If ignore history, we pass a temporary file path or handle logic.
            # Implemented inside generate_news_report would be cleaner, but for now let's just 
            # pass a dummy path if we don't want to load. 
            # But wait, generate_news_report LOADS and SAVES.
            # If we want to ignore loading but still save, we can't easily do that with current function.
            # Let's just modify the function call or use a temp file strategy if needed.
            # For simplicity in this script:
            # We will just pass the real history file. If ignore-history is set, we can
            # just delete the history file before running? No, that destroys data.
            # Best way: pass a flag to generate_news_report?
            # Let's just handle it by using a temporary empty history file if ignore flag is present, 
            # BUT this means we won't record what we saw.
            # If the user wants to populate history, they run without ignore.
            
            if args.ignore_history:
                 # Use a null device or temp file that we delete
                 target_history_file = 'temp_history_ignore.json'
                 if os.path.exists(target_history_file): os.remove(target_history_file)
            
            generate_news_report(holdings, args.news_report, target_history_file)

            if args.ignore_history and os.path.exists(target_history_file):
                os.remove(target_history_file)
            
            # Email Notification
            if args.email_to:
                send_email(
                    news_report, 
                    args.email_to, 
                    args.email_from, 
                    args.smtp_server, 
                    args.smtp_port, 
                    args.smtp_user, 
                    args.smtp_password
                )

            # Try to open only on appropriate OS
            if 'darwin' in sys.platform and not args.email_to:
                 # Only open if not emailing? or always open?
                 # Probably useful to see it anyway.
                try:
                    os.system(f"open {news_report}")
                except: pass
    else:
        print("No valid holdings found to process or file format error.")

def send_email(report_path, to_email, from_email, smtp_server, smtp_port, smtp_user, smtp_password):
    """
    Sends the HTML report via email.
    """
    import smtplib
    from email.mime.multipart import MIMEMultipart
    from email.mime.text import MIMEText
    
    print(f"Sending email to {to_email}...")
    
    try:
        with open(report_path, 'r', encoding='utf-8') as f:
            html_content = f.read()
            
        msg = MIMEMultipart('alternative')
        msg['Subject'] = f"Portfolio News Report - {datetime.now().strftime('%Y-%m-%d')}"
        msg['From'] = from_email
        msg['To'] = to_email
        
        part = MIMEText(html_content, 'html')
        msg.attach(part)
        
        # Connect to SMTP server
        server = smtplib.SMTP(smtp_server, int(smtp_port))
        server.starttls()
        
        if smtp_user and smtp_password:
            server.login(smtp_user, smtp_password)
            
        server.sendmail(from_email, to_email, msg.as_string())
        server.quit()
        
        print("Email sent successfully.")
        
    except Exception as e:
        print(f"Error sending email: {e}")

if __name__ == "__main__":
    main()
