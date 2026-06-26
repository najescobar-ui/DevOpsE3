CREATE DATABASE IF NOT EXISTS tienda_perritos;
USE tienda_perritos;

CREATE TABLE IF NOT EXISTS productos (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    descripcion VARCHAR(255),
    precio DECIMAL(10,2) NOT NULL,
    stock INT NOT NULL
);

INSERT INTO productos (nombre, descripcion, precio, stock) VALUES
('Tomates de campo', 'Cosechados esta manana, por kilo', 1990, 25),
('Lechuga costina', 'Hoja crujiente, recien cortada', 990, 40),
('Huevos de campo (docena)', 'De gallinas libres de la granja', 3490, 30),
('Zanahorias organicas', 'Dulces y frescas, por kilo', 1290, 35),
('Papas nativas', 'Saco de 2 kg', 2490, 20),
('Choclo fresco', 'Unidad grande de temporada', 790, 50),
('Zapallo italiano', 'Tierno, ideal para saltear', 1190, 28),
('Miel de abeja artesanal', 'Frasco 500g, directa de la granja', 5990, 18);
