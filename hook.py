#!/usr/bin/env python3
"""
N8N Domain Change Webhook Server - V3 Integrated
Sử dụng bash modules từ v3 thay vì tự implement
"""

HOOK_VERSION = "3.2"

import json
import subprocess
import re
import datetime
import sys
import signal
import os
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import socket
import errno

# Configuration
DEFAULT_PORT = 8888
LOG_DIR = "/var/log/n8npanel"
LOG_FILE = f"{LOG_DIR}/n8n-webhook.log"
PID_FILE = "/tmp/n8n-webhook.pid"
V3_WRAPPER_DIR = "/opt/n8npanel/v3/common"

# IP Whitelist
ALLOWED_IPS = [
    "123.25.21.12",
    "210.211.99.45", 
    "125.212.192.47",
    "103.57.223.33"
]

class RobustHTTPServer(HTTPServer):
    """HTTP Server với error handling"""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.settimeout(30.0)
        
    def handle_error(self, request, client_address):
        try:
            print(f"[WARN] Connection error from {client_address}")
        except:
            pass
    
    def finish_request(self, request, client_address):
        try:
            super().finish_request(request, client_address)
        except (ConnectionResetError, BrokenPipeError, OSError) as e:
            if hasattr(e, 'errno') and e.errno in (errno.ECONNRESET, errno.EPIPE, errno.ECONNABORTED):
                return
            print(f"[WARN] Network error: {e}")

class WebhookHandler(BaseHTTPRequestHandler):
    def log_webhook(self, level, message):
        """Log webhook events"""
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_message = f"[{timestamp}] [{level}] {message}"
        print(log_message)
        
        try:
            with open(LOG_FILE, "a") as f:
                f.write(log_message + "\n")
        except:
            pass

    def validate_domain(self, domain):
        """Validate domain format"""
        if not domain:
            return False
        # IP or domain
        if re.match(r'^(\d{1,3}\.){3}\d{1,3}$', domain):
            return True
        if re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$', domain):
            return True
        return False

    def validate_email(self, email):
        """Validate email format"""
        pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        return re.match(pattern, email) is not None

    def check_n8n_installation(self):
        """Check if N8N is running"""
        try:
            result = subprocess.run(['docker', 'ps'], 
                                  capture_output=True, text=True, timeout=10)
            return 'n8n' in result.stdout
        except:
            return False

    def get_server_ip(self):
        """Get server IP address"""
        try:
            result = subprocess.run(['curl', '-s', 'ifconfig.me'], 
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                return result.stdout.strip()
        except:
            pass
        
        try:
            result = subprocess.run(['hostname', '-I'], 
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                return result.stdout.strip().split()[0]
        except:
            pass
        
        return "127.0.0.1"

    def get_current_domain(self):
        """Get current domain from .env or docker-compose.yml"""
        # Try .env first (v3 way)
        env_file = "/root/n8n_data/.env"
        if os.path.exists(env_file):
            try:
                with open(env_file, 'r') as f:
                    for line in f:
                        if line.startswith('DOMAIN='):
                            domain = line.split('=', 1)[1].strip().strip('"').strip("'")
                            if domain:
                                return domain
            except:
                pass
        
        # Fallback to docker-compose.yml
        possible_paths = [
            "/root/n8n_data/docker-compose.yml",
            "/opt/n8n/docker-compose.yml",
            "/home/n8n/docker-compose.yml",
            "docker-compose.yml"
        ]
        
        for compose_file in possible_paths:
            try:
                if os.path.exists(compose_file):
                    with open(compose_file, "r") as f:
                        content = f.read()
                        
                        # Try different patterns for N8N_HOST
                        patterns = [
                            r'N8N_HOST=([^\s"\']+)',
                            r'N8N_HOST:\s*([^\s"\']+)',
                            r'"N8N_HOST":\s*"([^"]+)"',
                            r'N8N_HOST="([^"]+)"',
                            r"N8N_HOST='([^']+)'"
                        ]
                        
                        for pattern in patterns:
                            match = re.search(pattern, content)
                            if match:
                                domain = match.group(1).strip()
                                # Skip if it's a variable reference
                                if not domain.startswith('${'):
                                    return domain
            except:
                pass
        
        return "localhost"

    def change_domain_via_wrapper(self, domain, email):
        """
        Sử dụng domain_change_wrapper.sh từ v3
        Đây là cách ĐÚNG để tích hợp với v3
        """
        wrapper_script = f"{V3_WRAPPER_DIR}/domain_change_wrapper.sh"
        
        if not os.path.exists(wrapper_script):
            self.log_webhook("ERROR", f"Wrapper script not found: {wrapper_script}")
            return False
        
        try:
            self.log_webhook("INFO", f"Calling domain_change_wrapper: {domain}")
            
            # Gọi wrapper với timeout 10 phút
            result = subprocess.run(
                [wrapper_script, domain, email],
                capture_output=True,
                text=True,
                timeout=600
            )
            
            if result.returncode == 0:
                try:
                    # Parse JSON response
                    response = json.loads(result.stdout)
                    if response.get('success'):
                        self.log_webhook("SUCCESS", f"Domain changed to {domain}")
                        # Log stdout để debug
                        if result.stdout:
                            self.log_webhook("INFO", f"Wrapper output: {result.stdout[:500]}")
                        return True
                    else:
                        error_msg = response.get('message', 'Unknown error')
                        self.log_webhook("ERROR", f"Domain change failed: {error_msg}")
                        # Log stderr để debug
                        if result.stderr:
                            self.log_webhook("ERROR", f"Wrapper stderr: {result.stderr[:500]}")
                        return False
                except json.JSONDecodeError:
                    # Nếu không phải JSON, coi như thành công nếu returncode = 0
                    self.log_webhook("SUCCESS", f"Domain changed to {domain} (no JSON response)")
                    # Log output để debug
                    if result.stdout:
                        self.log_webhook("INFO", f"Wrapper stdout: {result.stdout[:500]}")
                    if result.stderr:
                        self.log_webhook("WARN", f"Wrapper stderr: {result.stderr[:500]}")
                    return True
            else:
                self.log_webhook("ERROR", f"Wrapper failed with code {result.returncode}")
                if result.stderr:
                    self.log_webhook("ERROR", f"Wrapper stderr: {result.stderr[:500]}")
                if result.stdout:
                    self.log_webhook("ERROR", f"Wrapper stdout: {result.stdout[:500]}")
                return False
                
        except subprocess.TimeoutExpired:
            self.log_webhook("ERROR", "Domain change timeout (10 minutes)")
            return False
        except Exception as e:
            self.log_webhook("ERROR", f"Exception calling wrapper: {str(e)}")
            return False

    def do_GET(self):
        """Handle GET requests"""
        path = urlparse(self.path).path
        
        if path == "/status":
            self.handle_status()
        elif path == "/health":
            self.handle_health()
        elif path == "/":
            self.handle_root()
        else:
            self.send_error_response(404, "Endpoint not found")

    def do_POST(self):
        """Handle POST requests"""
        path = urlparse(self.path).path
        
        if path == "/change-domain":
            self.handle_change_domain()
        else:
            self.send_error_response(404, "Endpoint not found")

    def handle_change_domain(self):
        """Handle domain change request"""
        try:
            # Check IP whitelist
            client_ip = self.get_client_ip()
            if client_ip not in ALLOWED_IPS:
                self.log_webhook("WARN", f"Unauthorized IP: {client_ip}")
                self.send_error_response(403, f"Access denied for IP {client_ip}")
                return
            
            # Parse request
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self.send_error_response(400, "Missing request body")
                return
            
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            domain = data.get('domain', '').strip()
            email = data.get('email', '').strip()
            
            # Validate
            if not domain or not self.validate_domain(domain):
                self.send_error_response(400, "Invalid domain")
                return
            
            if email and not self.validate_email(email):
                self.send_error_response(400, "Invalid email")
                return
            
            if not email:
                email = f"admin@{domain}"
            
            # Check N8N
            if not self.check_n8n_installation():
                self.send_error_response(500, "N8N not running")
                return
            
            # Send immediate response
            response = {
                "status": "success",
                "message": "Domain change initiated",
                "domain": domain,
                "email": email
            }
            self.send_json_response(200, response)
            
            # Start domain change in background
            import threading
            thread = threading.Thread(
                target=self.change_domain_via_wrapper,
                args=(domain, email)
            )
            thread.daemon = True
            thread.start()
            
        except json.JSONDecodeError:
            self.send_error_response(400, "Invalid JSON")
        except Exception as e:
            self.log_webhook("ERROR", f"Error: {str(e)}")
            self.send_error_response(500, "Internal server error")

    def handle_status(self):
        """Handle status request"""
        try:
            current_domain = self.get_current_domain()
            server_ip = self.get_server_ip()
            n8n_status = "running" if self.check_n8n_installation() else "stopped"
            
            response = {
                "status": n8n_status,
                "version": HOOK_VERSION,
                "server_ip": server_ip,
                "current_domain": current_domain,
                "timestamp": datetime.datetime.utcnow().isoformat() + "Z"
            }
            
            self.send_json_response(200, response)
        except Exception as e:
            self.log_webhook("ERROR", f"Error: {str(e)}")
            self.send_error_response(500, "Internal server error")
    
    def handle_health(self):
        """Health check"""
        response = {
            "health": "ok",
            "version": HOOK_VERSION,
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z"
        }
        self.send_json_response(200, response)

    def handle_root(self):
        """Root endpoint"""
        response = {
            "service": "N8N Domain Change Webhook API (V3 Integrated)",
            "version": HOOK_VERSION,
            "endpoints": {
                "POST /change-domain": "Change domain (IP whitelist required)",
                "GET /status": "Check status",
                "GET /health": "Health check"
            }
        }
        self.send_json_response(200, response)

    def send_json_response(self, status_code, data):
        """Send JSON response"""
        response = json.dumps(data, ensure_ascii=False)
        response_bytes = response.encode('utf-8')
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(response_bytes)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response_bytes)

    def send_error_response(self, status_code, message):
        """Send error response"""
        self.send_json_response(status_code, {"error": message})

    def log_message(self, format, *args):
        """Disable default HTTP logging"""
        pass
    
    def get_client_ip(self):
        """Get client IP"""
        forwarded = self.headers.get('X-Forwarded-For')
        if forwarded:
            return forwarded.split(',')[0].strip()
        
        real_ip = self.headers.get('X-Real-IP')
        if real_ip:
            return real_ip.strip()
        
        return self.client_address[0]

def signal_handler(sig, frame):
    """Handle Ctrl+C"""
    print("\n🛑 Stopping webhook server...")
    try:
        os.remove(PID_FILE)
    except:
        pass
    sys.exit(0)

def main():
    """Main function"""
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print("❌ Invalid port")
            sys.exit(1)
    
    # Create log directory (thống nhất với v3)
    os.makedirs(LOG_DIR, exist_ok=True)
    
    # Save PID
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))
    
    # Setup signal handler
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    print("🚀 N8N Webhook Server V3 Started!")
    print(f"🔌 Port: {port}")
    print(f"🌐 API: http://0.0.0.0:{port}/change-domain")
    print(f"📊 Status: http://0.0.0.0:{port}/status")
    print(f"📁 Logs: {LOG_FILE}")
    print(f"🔧 Using V3 modules from: {V3_WRAPPER_DIR}")
    print("💡 Press Ctrl+C to stop")
    
    try:
        httpd = RobustHTTPServer(('0.0.0.0', port), WebhookHandler)
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Stopping...")
        httpd.shutdown()
        httpd.server_close()
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
