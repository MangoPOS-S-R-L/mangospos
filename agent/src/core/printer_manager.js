const { v4: uuidv4 } = require('uuid');
const escpos = require('escpos');
const Network = require('escpos-network');
const USB = require('escpos-usb');
const Serial = require('escpos-serialport');
const { config, logger } = require('../config');
const fs = require('fs');

class PrinterManager {
    constructor() {
        this.jobs = []; // In-memory queue
        this.history = []; // History
        this.isProcessing = false;
    }

    _getConfiguredPrinters() {
        return Array.isArray(config.printers) ? config.printers : [];
    }

    _sanitizePrinterValue(value) {
        if (value == null) return null;
        const normalized = String(value).trim();
        return normalized.length > 0 ? normalized : null;
    }

    _buildPrinterCandidates(printer) {
        if (!printer || typeof printer !== 'object') return [];

        const values = [
            printer.id,
            printer.endpoint,
            printer.name,
            printer.ip,
            printer.ipAddress,
            printer.devicePath,
            printer.device_path,
            printer.mac,
            printer.portName,
            printer.port_name,
        ]
            .map((value) => this._sanitizePrinterValue(value))
            .filter(Boolean);

        const ip = this._sanitizePrinterValue(printer.ip || printer.ipAddress);
        if (ip) {
            values.push(`${ip}:${parseInt(printer.port, 10) || 9100}`);
        }

        return [...new Set(values)];
    }

    _normalizeProvidedPrinter(job) {
        const printer = job && job.printer && typeof job.printer === 'object'
            ? job.printer
            : null;
        if (!printer) return null;

        const type = this._sanitizePrinterValue(printer.type) || 'network';
        const normalized = {
            ...printer,
            id: this._sanitizePrinterValue(printer.id) || this._sanitizePrinterValue(job.printerId),
            name: this._sanitizePrinterValue(printer.name) || this._sanitizePrinterValue(job.printerId) || 'MangoPOS Assigned Printer',
            type,
        };

        if (type === 'network') {
            const ip = this._sanitizePrinterValue(printer.ip || printer.ipAddress);
            const port = parseInt(printer.port, 10) || 9100;
            normalized.endpoint = this._sanitizePrinterValue(printer.endpoint) || (ip ? `${ip}:${port}` : null);
        } else if (type === 'usb') {
            normalized.endpoint =
                this._sanitizePrinterValue(printer.endpoint) ||
                this._sanitizePrinterValue(printer.devicePath) ||
                this._sanitizePrinterValue(printer.device_path) ||
                this._sanitizePrinterValue(printer.mac) ||
                this._sanitizePrinterValue(printer.portName) ||
                this._sanitizePrinterValue(printer.port_name);
        } else if (type === 'serial' || type === 'bluetooth') {
            normalized.endpoint =
                this._sanitizePrinterValue(printer.endpoint) ||
                this._sanitizePrinterValue(printer.devicePath) ||
                this._sanitizePrinterValue(printer.device_path) ||
                this._sanitizePrinterValue(printer.mac);
        }

        return normalized;
    }

    _findConfiguredPrinter(job) {
        const printers = this._getConfiguredPrinters();
        const requestedId = this._sanitizePrinterValue(job.printerId);
        const requestedPrinter = job.printer && typeof job.printer === 'object'
            ? job.printer
            : null;
        const candidateKeys = new Set([
            requestedId,
            ...this._buildPrinterCandidates(requestedPrinter),
        ].filter(Boolean));

        for (const configuredPrinter of printers) {
            const configuredCandidates = new Set(this._buildPrinterCandidates(configuredPrinter));
            if (requestedId && configuredPrinter.id === requestedId) {
                return { ...configuredPrinter };
            }
            for (const key of candidateKeys) {
                if (configuredCandidates.has(key)) {
                    return { ...configuredPrinter };
                }
            }
        }

        if (requestedId && requestedId.includes(':')) {
            return {
                id: requestedId,
                name: requestedId,
                type: 'network',
                endpoint: requestedId,
            };
        }

        return this._normalizeProvidedPrinter(job);
    }

    addJob(job) {
        const normalizedJob = {
            ...job,
            id: uuidv4(),
            status: 'queued',
            createdAt: new Date(),
            retries: job.retries || 0,
            data: job.data || {
                type: job.type || 'text',
                content: job.content,
            },
        };

        this.jobs.push(normalizedJob);
        logger.info(`Job ${normalizedJob.id} queued for printer ${normalizedJob.printerId}`);
        process.nextTick(() => this.processQueue());
        return normalizedJob.id;
    }

    async processQueue() {
        if (this.isProcessing) return;
        this.isProcessing = true;

        const jobIndex = this.jobs.findIndex(j => j.status === 'queued' || j.status === 'retrying');
        if (jobIndex === -1) {
            this.isProcessing = false;
            return;
        }

        const job = this.jobs[jobIndex];
        job.status = 'printing';
        job.startedAt = new Date();

        try {
            const printerConfig = this._findConfiguredPrinter(job);
            if (!printerConfig) throw new Error(`Printer ${job.printerId} not found`);

            logger.info(
                `Processing job ${job.id} -> printer=${printerConfig.name || printerConfig.id} ` +
                `endpoint=${printerConfig.endpoint || 'n/a'} type=${job.data?.type}`
            );
            await this.printToDevice(printerConfig, job.data);

            job.status = 'completed';
            job.completedAt = new Date();
            logger.info(`Job ${job.id} completed successfully`);
        } catch (err) {
            logger.error(`Job ${job.id} failed: ${err.message}`);
            job.error = err.message;
            if (job.retries < (config.queue?.max_retries || 3)) {
                job.retries = (job.retries || 0) + 1;
                job.status = 'retrying';
                logger.warn(`Retrying job ${job.id} (${job.retries}/${config.queue.max_retries})`);
            } else {
                job.status = 'failed';
            }
        } finally {
            if (job.status === 'completed' || job.status === 'failed') {
                this.jobs.splice(jobIndex, 1);
                this.history.unshift(job);
                if (this.history.length > (config.queue?.history_limit || 100)) {
                    this.history.pop();
                }
            }
            this.isProcessing = false;
            process.nextTick(() => this.processQueue());
        }
    }

    async printToDevice(printerConfig, data) {
        return new Promise((resolve, reject) => {
            let device;
            try {
                if (printerConfig.type === 'network') {
                    const endpoint = this._sanitizePrinterValue(printerConfig.endpoint);
                    if (!endpoint || !endpoint.includes(':')) {
                        return reject(new Error(`Network printer endpoint missing or invalid for ${printerConfig.id || printerConfig.name}`));
                    }
                    const [ip, port] = endpoint.split(':');
                    logger.info(`Opening network printer connection -> ${ip}:${parseInt(port, 10) || 9100}`);
                    device = new Network(ip, parseInt(port, 10) || 9100);
                } else if (printerConfig.type === 'usb') {
                    let vid, pid;
                    if (printerConfig.vid && printerConfig.pid) {
                        vid = printerConfig.vid;
                        pid = printerConfig.pid;
                    } else if (printerConfig.endpoint && printerConfig.endpoint.includes('VID_')) {
                        const vMatch = printerConfig.endpoint.match(/VID_([0-9A-F]{4})/i);
                        const pMatch = printerConfig.endpoint.match(/PID_([0-9A-F]{4})/i);
                        if (vMatch) vid = parseInt(vMatch[1], 16);
                        if (pMatch) pid = parseInt(pMatch[1], 16);
                    }

                    if (vid && pid) {
                        logger.info(`Connecting to USB Printer: VID=${vid.toString(16)} PID=${pid.toString(16)}`);
                        device = new USB(vid, pid);
                    } else {
                        logger.warn(
                            `USB printer ${printerConfig.name || printerConfig.id} missing VID/PID. ` +
                            `Attempting auto-detect (endpoint=${printerConfig.endpoint || 'n/a'})`
                        );
                        device = new USB();
                    }
                } else if (printerConfig.type === 'serial' || printerConfig.type === 'bluetooth') {
                    const endpoint = this._sanitizePrinterValue(printerConfig.endpoint);
                    if (!endpoint) {
                        return reject(new Error(`Serial/Bluetooth printer endpoint missing for ${printerConfig.id || printerConfig.name}`));
                    }
                    device = new Serial(endpoint);
                } else {
                    return reject(new Error(`Unsupported printer type: ${printerConfig.type}`));
                }
            } catch (e) {
                return reject(e);
            }

            const options = { encoding: 'GB18030' };
            const printer = new escpos.Printer(device, options);

            device.open((err) => {
                if (err) {
                    logger.error(`Failed opening device for printer ${printerConfig.id || printerConfig.name}: ${err.message || err}`);
                    return reject(err);
                }

                if (data.type === 'raw') {
                    const buffer = Buffer.from(data.content, 'base64');
                    logger.info(`Sending RAW job to printer ${printerConfig.id || printerConfig.name} -> bytes=${buffer.length}`);
                    printer.raw(buffer).close();
                    resolve();
                } else if (data.type === 'text') {
                    logger.info(`Sending TEXT job to printer ${printerConfig.id || printerConfig.name} -> chars=${(data.content || '').length}`);
                    printer.text(data.content).cut().close();
                    resolve();
                } else {
                    printer.close();
                    resolve();
                }
            });
        });
    }

    getQueueStatus() {
        return {
            active: this.jobs.length,
            history: this.history.length,
            jobs: this.jobs,
        };
    }
}

module.exports = new PrinterManager();
