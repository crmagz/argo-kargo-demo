const express = require('express');
const redis = require('redis');
const promClient = require('prom-client');
const winston = require('winston');

// Initialize Express app
const app = express();
app.use(express.json());

// Configuration
const PORT = process.env.PORT || 8080;
const REDIS_HOST = process.env.REDIS_HOST || 'redis-master';
const REDIS_PORT = process.env.REDIS_PORT || 6379;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || 'redis_password';
const CACHE_TTL = parseInt(process.env.CACHE_TTL) || 300; // 5 minutes default

// Configure Winston logger
const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  defaultMeta: {
    service: 'product-api',
    namespace: 'infosec-artillery'
  },
  transports: [
    new winston.transports.Console()
  ]
});

// In-memory product store (simulating a database)
const products = new Map([
  [1, { id: 1, name: 'Laptop', description: 'High-performance laptop', price: 1299.99, category: 'electronics', stock: 50 }],
  [2, { id: 2, name: 'Wireless Mouse', description: 'Ergonomic wireless mouse', price: 29.99, category: 'electronics', stock: 200 }],
  [3, { id: 3, name: 'Mechanical Keyboard', description: 'RGB mechanical keyboard', price: 149.99, category: 'electronics', stock: 75 }],
  [4, { id: 4, name: 'USB-C Hub', description: '7-in-1 USB-C hub', price: 49.99, category: 'accessories', stock: 150 }],
  [5, { id: 5, name: 'Monitor Stand', description: 'Adjustable monitor stand', price: 79.99, category: 'accessories', stock: 100 }],
  [6, { id: 6, name: 'Headphones', description: 'Noise-cancelling headphones', price: 299.99, category: 'audio', stock: 60 }],
  [7, { id: 7, name: 'Webcam', description: '1080p webcam', price: 89.99, category: 'electronics', stock: 120 }],
  [8, { id: 8, name: 'Desk Lamp', description: 'LED desk lamp', price: 39.99, category: 'accessories', stock: 180 }],
  [9, { id: 9, name: 'External SSD', description: '1TB external SSD', price: 159.99, category: 'storage', stock: 90 }],
  [10, { id: 10, name: 'Phone Stand', description: 'Adjustable phone stand', price: 19.99, category: 'accessories', stock: 250 }]
]);

let nextProductId = 11;

// Redis client
let redisClient;

async function connectRedis() {
  try {
    redisClient = redis.createClient({
      socket: {
        host: REDIS_HOST,
        port: REDIS_PORT
      },
      password: REDIS_PASSWORD
    });

    redisClient.on('error', (err) => {
      logger.error('Redis client error', { error: err.message });
    });

    redisClient.on('connect', () => {
      logger.info('Connected to Redis');
    });

    redisClient.on('reconnecting', () => {
      logger.warn('Reconnecting to Redis');
    });

    await redisClient.connect();

    // Cache warming on startup
    await warmCache();

  } catch (error) {
    logger.error('Failed to connect to Redis', { error: error.message });
    // Continue without cache
  }
}

// Cache warming - preload frequently accessed data
async function warmCache() {
  try {
    if (!redisClient || !redisClient.isOpen) return;

    logger.info('Warming cache with product data');

    // Cache all products list
    const productList = Array.from(products.values());
    await redisClient.setEx(
      'products:all',
      CACHE_TTL,
      JSON.stringify(productList)
    );

    // Cache individual products
    for (const [id, product] of products.entries()) {
      await redisClient.setEx(
        `product:${id}`,
        CACHE_TTL,
        JSON.stringify(product)
      );
    }

    logger.info('Cache warmed successfully', { productCount: products.size });
  } catch (error) {
    logger.error('Failed to warm cache', { error: error.message });
  }
}

// Prometheus metrics
const register = new promClient.Registry();
promClient.collectDefaultMetrics({ register });

const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5]
});

const httpRequestTotal = new promClient.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code']
});

const cacheHitsTotal = new promClient.Counter({
  name: 'cache_hits_total',
  help: 'Total number of cache hits',
  labelNames: ['key_type']
});

const cacheMissesTotal = new promClient.Counter({
  name: 'cache_misses_total',
  help: 'Total number of cache misses',
  labelNames: ['key_type']
});

const cacheOperationDuration = new promClient.Histogram({
  name: 'cache_operation_duration_seconds',
  help: 'Duration of cache operations in seconds',
  labelNames: ['operation'],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1]
});

register.registerMetric(httpRequestDuration);
register.registerMetric(httpRequestTotal);
register.registerMetric(cacheHitsTotal);
register.registerMetric(cacheMissesTotal);
register.registerMetric(cacheOperationDuration);

// Middleware to track request metrics
app.use((req, res, next) => {
  const start = Date.now();

  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route ? req.route.path : req.path;

    httpRequestDuration
      .labels(req.method, route, res.statusCode)
      .observe(duration);

    httpRequestTotal
      .labels(req.method, route, res.statusCode)
      .inc();
  });

  next();
});

// Request logging middleware
app.use((req, res, next) => {
  logger.info('Incoming request', {
    method: req.method,
    path: req.path,
    ip: req.ip
  });
  next();
});

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    let redisStatus = 'disconnected';

    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      await redisClient.ping();
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('ping').observe(duration);
      redisStatus = 'connected';
    }

    res.status(200).json({
      status: 'healthy',
      service: 'product-api',
      timestamp: new Date().toISOString(),
      redis: redisStatus,
      productsCount: products.size
    });
  } catch (error) {
    logger.error('Health check failed', { error: error.message });
    res.status(503).json({
      status: 'unhealthy',
      service: 'product-api',
      timestamp: new Date().toISOString(),
      error: error.message
    });
  }
});

// Readiness check endpoint
app.get('/ready', (req, res) => {
  res.status(200).json({
    ready: true,
    redis: redisClient && redisClient.isOpen ? 'connected' : 'disconnected'
  });
});

// Metrics endpoint for Prometheus
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// GET /products - List all products (with caching)
app.get('/products', async (req, res) => {
  const category = req.query.category;

  try {
    let productList;
    let cacheKey = 'products:all';

    if (category) {
      cacheKey = `products:category:${category}`;
    }

    // Try cache first
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      const cached = await redisClient.get(cacheKey);
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('get').observe(duration);

      if (cached) {
        cacheHitsTotal.labels('product_list').inc();
        productList = JSON.parse(cached);
        logger.info('Cache hit for product list', { category, count: productList.length });

        return res.status(200).json({
          data: productList,
          cached: true,
          count: productList.length
        });
      } else {
        cacheMissesTotal.labels('product_list').inc();
      }
    }

    // Cache miss - get from "database"
    if (category) {
      productList = Array.from(products.values()).filter(p => p.category === category);
    } else {
      productList = Array.from(products.values());
    }

    // Update cache
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      await redisClient.setEx(cacheKey, CACHE_TTL, JSON.stringify(productList));
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('set').observe(duration);
    }

    logger.info('Retrieved products from database', { category, count: productList.length });

    res.status(200).json({
      data: productList,
      cached: false,
      count: productList.length
    });
  } catch (error) {
    logger.error('Error listing products', { error: error.message });
    res.status(500).json({ error: 'Internal server error', message: error.message });
  }
});

// GET /products/:id - Get product by ID (with caching)
app.get('/products/:id', async (req, res) => {
  const id = parseInt(req.params.id);

  if (isNaN(id)) {
    return res.status(400).json({ error: 'Invalid product ID' });
  }

  try {
    const cacheKey = `product:${id}`;

    // Try cache first
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      const cached = await redisClient.get(cacheKey);
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('get').observe(duration);

      if (cached) {
        cacheHitsTotal.labels('product').inc();
        const product = JSON.parse(cached);
        logger.info('Cache hit for product', { productId: id });

        return res.status(200).json({
          ...product,
          cached: true
        });
      } else {
        cacheMissesTotal.labels('product').inc();
      }
    }

    // Cache miss - get from "database"
    const product = products.get(id);

    if (!product) {
      logger.warn('Product not found', { productId: id });
      return res.status(404).json({ error: 'Product not found' });
    }

    // Update cache
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      await redisClient.setEx(cacheKey, CACHE_TTL, JSON.stringify(product));
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('set').observe(duration);
    }

    logger.info('Retrieved product from database', { productId: id });

    res.status(200).json({
      ...product,
      cached: false
    });
  } catch (error) {
    logger.error('Error retrieving product', { productId: id, error: error.message });
    res.status(500).json({ error: 'Internal server error', message: error.message });
  }
});

// POST /products - Create new product (invalidate cache)
app.post('/products', async (req, res) => {
  const { name, description, price, category, stock } = req.body;

  // Validation
  if (!name || !price || !category) {
    return res.status(400).json({ error: 'name, price, and category are required' });
  }

  if (typeof price !== 'number' || price <= 0) {
    return res.status(400).json({ error: 'price must be a positive number' });
  }

  try {
    const product = {
      id: nextProductId++,
      name,
      description: description || '',
      price,
      category,
      stock: stock || 0
    };

    products.set(product.id, product);

    // Invalidate relevant caches
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      await Promise.all([
        redisClient.del('products:all'),
        redisClient.del(`products:category:${category}`)
      ]);
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('del').observe(duration);
    }

    logger.info('Created product', { productId: product.id, name, category });

    res.status(201).json(product);
  } catch (error) {
    logger.error('Error creating product', { error: error.message });
    res.status(500).json({ error: 'Internal server error', message: error.message });
  }
});

// PUT /products/:id - Update product (invalidate cache)
app.put('/products/:id', async (req, res) => {
  const id = parseInt(req.params.id);
  const { name, description, price, category, stock } = req.body;

  if (isNaN(id)) {
    return res.status(400).json({ error: 'Invalid product ID' });
  }

  const product = products.get(id);

  if (!product) {
    logger.warn('Product not found for update', { productId: id });
    return res.status(404).json({ error: 'Product not found' });
  }

  if (price !== undefined && (typeof price !== 'number' || price <= 0)) {
    return res.status(400).json({ error: 'price must be a positive number' });
  }

  try {
    const oldCategory = product.category;

    // Update product
    if (name !== undefined) product.name = name;
    if (description !== undefined) product.description = description;
    if (price !== undefined) product.price = price;
    if (category !== undefined) product.category = category;
    if (stock !== undefined) product.stock = stock;

    products.set(id, product);

    // Invalidate caches
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      const keysToDelete = [
        `product:${id}`,
        'products:all',
        `products:category:${oldCategory}`
      ];

      if (category && category !== oldCategory) {
        keysToDelete.push(`products:category:${category}`);
      }

      await Promise.all(keysToDelete.map(key => redisClient.del(key)));
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('del').observe(duration);
    }

    logger.info('Updated product', { productId: id });

    res.status(200).json(product);
  } catch (error) {
    logger.error('Error updating product', { productId: id, error: error.message });
    res.status(500).json({ error: 'Internal server error', message: error.message });
  }
});

// DELETE /products/:id - Delete product (invalidate cache)
app.delete('/products/:id', async (req, res) => {
  const id = parseInt(req.params.id);

  if (isNaN(id)) {
    return res.status(400).json({ error: 'Invalid product ID' });
  }

  const product = products.get(id);

  if (!product) {
    logger.warn('Product not found for deletion', { productId: id });
    return res.status(404).json({ error: 'Product not found' });
  }

  try {
    const category = product.category;
    products.delete(id);

    // Invalidate caches
    if (redisClient && redisClient.isOpen) {
      const start = Date.now();
      await Promise.all([
        redisClient.del(`product:${id}`),
        redisClient.del('products:all'),
        redisClient.del(`products:category:${category}`)
      ]);
      const duration = (Date.now() - start) / 1000;
      cacheOperationDuration.labels('del').observe(duration);
    }

    logger.info('Deleted product', { productId: id });

    res.status(204).send();
  } catch (error) {
    logger.error('Error deleting product', { productId: id, error: error.message });
    res.status(500).json({ error: 'Internal server error', message: error.message });
  }
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Error handler
app.use((err, req, res, next) => {
  logger.error('Unhandled error', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'Internal server error' });
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  logger.info('SIGTERM signal received: closing connections');
  if (redisClient) await redisClient.quit();
  process.exit(0);
});

process.on('SIGINT', async () => {
  logger.info('SIGINT signal received: closing connections');
  if (redisClient) await redisClient.quit();
  process.exit(0);
});

// Initialize and start server
async function start() {
  await connectRedis();

  app.listen(PORT, '0.0.0.0', () => {
    logger.info(`Product API listening on port ${PORT}`);
  });
}

start().catch((error) => {
  logger.error('Failed to start server', { error: error.message });
  process.exit(1);
});
