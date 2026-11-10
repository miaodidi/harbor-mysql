-- For a disposable local test server only. No real customer data.
CREATE DATABASE IF NOT EXISTS harbor_preview CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE harbor_preview;
CREATE TABLE IF NOT EXISTS users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at DATETIME
);
INSERT IGNORE INTO users VALUES
 (101,'赵宁','zhaoning@example.com','active','2026-11-07 15:47:00'),
 (102,'李安','lian@example.com','active','2026-11-08 10:12:00'),
 (103,'王一帆','yifan@example.com','inactive','2026-11-08 11:36:00'),
 (104,'苏然','suran@example.com','active','2026-11-09 14:22:00'),
 (105,'许知远','zhiyuan@example.com','active','2026-11-09 16:05:00'),
 (106,'周可','zhouke@example.com','inactive','2026-11-09 18:30:00'),
 (107,'陈默','chenmo@example.com','active','2026-11-10 09:18:00'),
 (108,'林小雨','xiaoyu@example.com','active','2026-11-10 09:42:00');
CREATE TABLE IF NOT EXISTS orders (id INT PRIMARY KEY, user_id INT, total DECIMAL(10,2), status VARCHAR(20));
CREATE TABLE IF NOT EXISTS products (id INT PRIMARY KEY, name VARCHAR(100), price DECIMAL(10,2));
