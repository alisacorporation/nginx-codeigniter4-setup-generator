#!/bin/bash

# nginx-codeigniter4-setup-generator

# https://github.com/alisacorporation
# https://github.com/alisacorporation/nginx-codeigniter4-setup-generator/

# Variables
PROJECT_NAME=$1
SKIP_SSL=${2:-false}
DOMAIN_NAME="${PROJECT_NAME}"
VHOST_DIR="/etc/nginx/vhost"
PROJECT_DIR="/var/www/html/$DOMAIN_NAME"
NGINX_VHOST="/etc/nginx/vhost/$DOMAIN_NAME.conf"
LOG_DIR="/var/log/nginx/$DOMAIN_NAME"

# Get the real user who initiated the script
REAL_USER=$(ps -o user= -p $PPID)

# Check if the script is run as superuser
if [ "$EUID" -ne 0 ]; then
	echo "Please run the script with superuser privileges."
	exit 1
fi

# Check if a project name is provided
if [ -z "$PROJECT_NAME" ]; then
	echo "Usage: $0 project_name"
	exit 1
fi

# Make sure we have general nginx directory to working with
if [ ! -d "/etc/nginx" ]; then
  echo "Directory '/etc/nginx' does not exist. Make sure you have installed nginx!"
  exit 1;
fi

# Function to create directory if it doesn't exist
create_dir() {
  local dir_path=$1
  if [ ! -d "$dir_path" ]; then
    sudo mkdir -p "$dir_path"
    if [ ! -d "$dir_path" ]; then
      echo "Failed to create directory: '$dir_path'"
      exit 1
    else
      echo "Created directory: '$dir_path'"
    fi
  fi
}

# Create project and log directories
echo "Creating directories..."

# Create both directories
create_dir "$VHOST_DIR"
create_dir "$PROJECT_DIR"
create_dir "$LOG_DIR"

# Create NGINX virtual host file using touch
sudo touch "$NGINX_VHOST" || {
	echo "Failed to create file $NGINX_VHOST"
	exit 1
}

# Download CodeIgniter 4 (if you have a ready archive)
echo "Downloading CodeIgniter..."
wget https://api.github.com/repos/codeigniter4/framework/zipball/v4.5.7 -O /tmp/codeigniter.zip
unzip /tmp/codeigniter.zip -d /tmp/codeigniter

# Find the extracted directory (with the name codeigniter4-framework-XXXX)
FRAMEWORK_DIR=$(find /tmp/codeigniter -mindepth 1 -maxdepth 1 -type d)

# Copy the contents of the framework directory to the target project directory
rsync -a "$FRAMEWORK_DIR/" "$PROJECT_DIR"

# Clean up temporary files
sudo rm -rf /tmp/codeigniter /tmp/codeigniter.zip

# Create NGINX configuration
echo "Creating NGINX configuration..."
sudo bash -c "cat > $NGINX_VHOST" <<EOL
server {
    listen 443 ssl;
    server_name $DOMAIN_NAME;

    http2 on;

    ssl_certificate /etc/nginx/ssl/$DOMAIN_NAME.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN_NAME.key;

    root $PROJECT_DIR/public;
    index index.php;

    access_log $LOG_DIR/access.log;
    error_log $LOG_DIR/error.log;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    # Caching static files
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    location ~ \.php$ {
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_pass php-fpm;
    }

    # Error handling
    error_page 404 /index.php;
}

server {
    listen 80;
    server_name $DOMAIN_NAME;
    return 301 https://$DOMAIN_NAME\$request_uri;
}
EOL

# Generate SSL certificate using OpenSSL (Self-Signed)
if [ "$SKIP_SSL" != "true" ]; then
    echo "Generating SSL certificate..."
    sudo mkdir -p /etc/nginx/ssl
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 -keyout /etc/nginx/ssl/"$DOMAIN_NAME".key -out /etc/nginx/ssl/"$DOMAIN_NAME".crt -subj "/CN=$DOMAIN_NAME"
else
    echo "Skipping SSL certificate generation..."
fi

# Paths to environment files
ENV_FILE="$PROJECT_DIR/env"
DOT_ENV_FILE="$PROJECT_DIR/.env"

# Check if the env file exists
if [ ! -f "$ENV_FILE" ]; then
	echo "File $ENV_FILE not found!"
	exit 1
fi

# Copy the env file to .env
cp "$ENV_FILE" "$DOT_ENV_FILE" && echo ".env file created successfully."

# Change the environment string to development
sed -i 's/# CI_ENVIRONMENT = production/CI_ENVIRONMENT = development/' "$DOT_ENV_FILE"

echo "Development environment set in .env."

# Add the domain to /etc/hosts
echo "Adding $DOMAIN_NAME to /etc/hosts..."
sudo sed -i "/$DOMAIN_NAME/d" /etc/hosts
echo "127.0.0.1 $DOMAIN_NAME" | sudo tee -a /etc/hosts

# Reload NGINX to apply changes
echo "Reloading NGINX..."
sudo systemctl reload nginx

echo "Project $PROJECT_NAME created successfully and accessible at https://$DOMAIN_NAME"

# Change ownership and permissions of the project directory
sudo chown -R "$REAL_USER":"$REAL_USER" "$PROJECT_DIR"
sudo chmod -R 777 "$PROJECT_DIR"/writable

# Test Nginx configuration and reload if valid
if sudo nginx -t; then
    echo "Configuration valid. Reloading NGINX..."
    sudo systemctl reload nginx
else
    echo "Configuration test failed. Fix errors before reloading."
    exit 1
fi