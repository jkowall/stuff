# Schwab to Seeking Alpha Sync Tool

This tool helps you synchronize your Charles Schwab portfolio with Seeking Alpha and view recent news for your holdings.

## Features

- **CSV Conversion**: Converts Schwab's portfolio export CSV into a format importable by Seeking Alpha.
- **News Report**: Generates an HTML report with the latest news for your holdings from Google News.
- **Privacy-Focused**: No API keys required. Runs locally on your machine.

## Prerequisites

- Python 3 installed on your system.
- No external libraries required (uses standard Python libraries).

## Usage

1. **Export from Schwab**:
   - Log in to your Charles Schwab account.
   - Go to your "Accounts" or "Positions" view.
   - Look for the "Export" link (usually top right of the table) and download the CSV file.

2. **Run the Script**:
   Open your terminal and navigate to this directory:

   ```bash
   cd /Users/jkowall/Library/CloudStorage/OneDrive-Personal/Stuff/finance_tools
   ```

   Run the script with your export file:

   ```bash
   python3 schwab_sync.py /path/to/your/schwab_export.csv
   ```

   **Options**:
   - `--output_csv`: Specify output filename (default: `seeking_alpha_import.csv`).
   - `--news_report`: Specify report filename (default: `portfolio_news.html`).
   - `--skip-news`: Skip fetching news if you only want the CSV.
   - `--history_file`: Path to store news history (default: `news_history.json`).
   - `--ignore-history`: Ignore history file and show all news.

   **Email Notification**:
   To send the report via email, use the following arguments (example for Gmail):

   ```bash
   python3 schwab_sync.py ~/Downloads/Account_Positions.csv \
     --email_to "your_email@gmail.com" \
     --email_from "your_email@gmail.com" \
     --smtp_user "your_email@gmail.com" \
     --smtp_password "your_app_password"
   ```

   *Note: For Gmail, you will likely need to generate an [App Password](https://myaccount.google.com/apppasswords).*

   **Example**:

   ```bash
   python3 schwab_sync.py ~/Downloads/Account_Positions.csv
   ```

3. **Import to Seeking Alpha**:
   - Go to [Seeking Alpha Portfolios](https://seekingalpha.com/account/portfolios).
   - Create a new portfolio or edit an existing one.
   - Choose "Upload File" and select the generated `seeking_alpha_import.csv`.

4. **View News**:
   - The script will automatically try to open `portfolio_news.html` in your browser.
   - You can also open it manually to see the latest news for your synced tickers.

## Note

- The script assumes the Schwab export contains a "Symbol", "Quantity", and "Cost Basis" column.
- News is fetched via Google News RSS.
