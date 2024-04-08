import socket
import time

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(("127.0.0.1", 6379))
sock.sendall("+PING\r\n".encode())
data = sock.recv(1024)
print(data.decode())
