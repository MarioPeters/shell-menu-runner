#!/bin/bash
# Simple Docker Task Runner

echo "=== DOCKER TASKS ==="
echo "1. 🐳 Up - Start containers"
echo "2. 🐳 Down - Stop containers" 
echo "3. 🐳 Logs - Follow logs"
echo "4. 🐳 Restart - Restart containers"
echo "5. 🐳 Ps - Show status"
echo "6. ❌ Exit"
echo ""
read -p "Select task [1-6]: " choice

case $choice in
    1) echo "Running: docker-compose up -d"; docker-compose up -d ;;
    2) echo "Running: docker-compose down"; docker-compose down ;;
    3) echo "Running: docker-compose logs -f --tail=200"; docker-compose logs -f --tail=200 ;;
    4) echo "Running: docker-compose restart"; docker-compose restart ;;
    5) echo "Running: docker-compose ps"; docker-compose ps ;;
    6) echo "Exiting..."; exit 0 ;;
    *) echo "Invalid selection" ;;
esac