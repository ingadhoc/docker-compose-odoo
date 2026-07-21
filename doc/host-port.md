# Host port

```sh
sudo ufw insert 1 allow from 172.60.0.0/16 to any port <PORT> proto tcp
# o de una toda la subred para dev: 
sudo ufw insert 1 allow from 172.60.0.0/16
```
