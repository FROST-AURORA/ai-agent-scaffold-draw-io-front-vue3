# Docker Deployment

This project is deployed as prebuilt Vite static files served by Nginx.

## 1. Build the frontend locally

Run this command on your development machine:

```bash
npm run build
```

After it succeeds, the production files are generated in:

```text
dist/
```

## 2. Upload files to the cloud server

Create a deployment directory on the server, for example:

```bash
mkdir -p /opt/ai-draw-io-front-vue
```

Upload these required files and directories into `/opt/ai-draw-io-front-vue`:

```text
dist/
Dockerfile
docker-compose.yml
nginx.conf
```

`.dockerignore` is optional for this deployment. It is only useful when the Docker build context contains extra project files such as `node_modules`, `.git`, or source code.

The server directory should look like this:

```text
/opt/ai-draw-io-front-vue/
  Dockerfile
  docker-compose.yml
  nginx.conf
  dist/
    index.html
    assets/
    images/
```

## 3. Build the Docker image on the server

Go to the deployment directory:

```bash
cd /opt/ai-draw-io-front-vue
```

Build the image:

```bash
docker compose build
```

The generated image name is:

```text
ai-draw-io-front-vue:1.0
```

You can check it with:

```bash
docker images | grep ai-draw-io-front-vue
```

## 4. Start the container

```bash
docker compose up -d
```

The default API base URL is `/api/v1`. Nginx proxies this path to the backend container `ai-draw-io-app:8093`.

If the frontend and backend are not in the same Compose file or Docker network, set `NEXT_PUBLIC_API_BASE_URL` in `docker-compose.yml` to the backend public address, for example:

```yaml
environment:
  - NEXT_PUBLIC_API_BASE_URL=http://SERVER_IP:8093/api/v1
```

Check the container status:

```bash
docker compose ps
```

View logs:

```bash
docker compose logs -f
```

## 5. Access the frontend

Open this URL in a browser:

```text
http://SERVER_IP:5173
```

If the cloud server has a firewall or security group, open inbound TCP port `5173`.

## 6. Update deployment later

Build a new `dist` locally:

```bash
npm run build
```

Upload and replace the server `dist/` directory, then rebuild and restart:

```bash
cd /opt/ai-draw-io-front-vue
docker compose build --no-cache
docker compose up -d
```

## Useful commands

Stop the service:

```bash
docker compose down
```

Restart the service:

```bash
docker compose restart
```

Remove the old image manually:

```bash
docker image rm ai-draw-io-front-vue:1.0
```
