#!/bin/bash
# Install Video Downloader dependencies
set -e

echo "🎬 Video Downloader - Dependency Installer"
echo "==========================================="

# Check Python
if ! command -v python3 &>/dev/null; then
    echo "❌ python3 not found. Please install Python 3."
    exit 1
fi
echo "✅ python3: $(python3 --version)"

# Check ffmpeg
if ! command -v ffmpeg &>/dev/null && ! [ -f "/opt/homebrew/bin/ffmpeg" ]; then
    echo "⚠️  ffmpeg not found. Installing via Homebrew..."
    brew install ffmpeg
else
    echo "✅ ffmpeg: $(ffmpeg -version 2>&1 | head -1)"
fi

# Create venv if not exists
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/../venv"

if [ ! -d "$VENV_DIR" ]; then
    echo "📦 Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

# Activate and install
source "$VENV_DIR/bin/activate"
echo "📦 Installing yt-dlp..."
pip install --quiet yt-dlp

echo ""
echo "✅ All dependencies installed!"
echo ""
echo "To test:"
echo "  source venv/bin/activate"
echo "  python3 backend/downloader.py detect 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'"
