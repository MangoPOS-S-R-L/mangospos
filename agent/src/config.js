const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const system = require('systeminformation');
const winston = require('winston');

const isPkg = typeof process.pkg !== 'undefined';
const baseDir = isPkg ? path.dirname(process.execPath) : path.join(__dirname, '..');

const CONFIG_PATH = path.join(baseDir, 'config.yaml');
const LOGS_DIR = path.join(baseDir, 'logs');

if (!fs.existsSync(LOGS_DIR)) {
    fs.mkdirSync(LOGS_DIR, { recursive: true });
}

const logger = winston.createLogger({
    level: 'info',
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.printf((info) => `[${info.timestamp}] [${info.level.toUpperCase()}] ${info.message}`)
    ),
    transports: [
        new winston.transports.Console(),
        new winston.transports.File({ filename: path.join(LOGS_DIR, 'agent.log') })
    ]
});


// Default Config Structure
const DEFAULT_CONFIG = {
    service: {
        port: 9100,
    },
    security: {
        enabled: true,
        api_token: 'default_token',
        whitelist: ['127.0.0.1']
    },
    discovery: {
        enabled: true,
        protocols: ['network', 'usb'],
    },
    printers: []
};

// Load Config
let config = { ...DEFAULT_CONFIG };

try {
    if (fs.existsSync(CONFIG_PATH)) {
        const fileContents = fs.readFileSync(CONFIG_PATH, 'utf8');
        const parsed = yaml.load(fileContents);
        config = { ...DEFAULT_CONFIG, ...parsed };
    } else {
        logger.warn(`No config.yaml found at ${CONFIG_PATH}. Using defaults.`);
    }
} catch (e) {
    logger.error(`Error loading config.yaml: ${e}`);
}

module.exports = { config, logger };
