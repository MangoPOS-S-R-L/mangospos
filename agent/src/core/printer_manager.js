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
        this.printers = config.printers || [];
        this.isProcessing = false;
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

        // Process next pending job
        const jobIndex = this.jobs.findIndex(j => j.status === 'queued' || j.status === 'retrying');
        if (jobIndex === -1) {
            this.isProcessing = false;
            return;
        }

        const job = this.jobs[jobIndex];
        job.status = 'printing';
        job.startedAt = new Date();

        try {
            // Find printer config
            let printerConfig = this.printers.find(p => p.id === job.printerId);

            if (!printerConfig && typeof job.printerId === 'string' && job.printerId.includes(':')) {
                printerConfig = {
                    id: job.printerId,
                    name: job.printerId,
                    type: 'network',
                    endpoint: job.printerId,
                };
            }

            if (!printerConfig) throw new Error(`Printer ${job.printerId} not found`);

            logger.info(`Processing job ${job.id} -> printer=${printerConfig.name || printerConfig.id} endpoint=${printerConfig.endpoint || 'n/a'} type=${job.data?.type}`);
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
            // Remove from active queue if completed/failed, move to history
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
                    const [ip, port] = printerConfig.endpoint.split(':');
                    logger.info(`Opening network printer connection -> ${ip}:${parseInt(port) || 9100}`);
                    device = new Network(ip, parseInt(port) || 9100);
                } else if (printerConfig.type === 'usb') {
                    // Native USB detection/printing requires correct VID/PID
                    // printerConfig should have { vid: 0xXXXX, pid: 0xXXXX }
                    // Or we can parse it from endpoint string if it was stored as "USB\VID_..."
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
                        // Fallback to auto-detect first printer? Or specific error
                        logger.warn('USB Printer config missing VID/PID. Attempting auto-detect...');
                        device = new USB();
                    }
                } else if (printerConfig.type === 'serial' || printerConfig.type === 'bluetooth') {
                    // Bluetooth POS printers usually map to a Virtual COM Port (Window) 
                    // or /dev/rfcomm (Linux). We use Serial connection.
                    device = new Serial(printerConfig.endpoint);
                } else {
                    return reject(new Error(`Unsupported printer type: ${printerConfig.type}`));
                }
            } catch (e) {
                return reject(e);
            }

            const options = { encoding: "GB18030" /* Default for many POS printers */ };

            // bluetooth/serial devices often need autoFlush: false for performance
            const printer = new escpos.Printer(device, options);

            device.open((err) => {
                if (err) {
                    logger.error(`Failed opening device for printer ${printerConfig.id || printerConfig.name}: ${err.message || err}`);
                    return reject(err);
                }

                // If sending raw hex/base64
                if (data.type === 'raw') {
                    const buffer = Buffer.from(data.content, 'base64');
                    logger.info(`Sending RAW job to printer ${printerConfig.id || printerConfig.name} -> bytes=${buffer.length}`);
                    printer
                        .raw(buffer)
                        .close();
                    resolve();
                } else if (data.type === 'text') {
                    logger.info(`Sending TEXT job to printer ${printerConfig.id || printerConfig.name} -> chars=${(data.content || '').length}`);
                    printer
                        .text(data.content)
                        .cut()
                        .close();
                    resolve();
                } else {
                    // Example structured receipt
                    // printer.text(...)
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
            jobs: this.jobs
        };
    }
}

module.exports = new PrinterManager();
