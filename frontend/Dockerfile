FROM nginx:alpine

# Copiar configuraci�n de NGINX
COPY default.conf /etc/nginx/conf.d/default.conf

# Copiar archivos estaticos
COPY index.html /usr/share/nginx/html/
COPY app.js /usr/share/nginx/html/
COPY img/ /usr/share/nginx/html/img/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
