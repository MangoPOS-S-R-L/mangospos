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
        job.id = uuidv4();
        job.status = 'queued';
        job.createdAt = new Date();
        this.jobs.push(job);
        logger.info(`Job ${job.id} queued for printer ${job.printerId}`);
        process.nextTick(() => this.processQueue());
        return job.id;
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
            const printerConfig = this.printers.find(p => p.id === job.printerId);
            if (!printerConfig) throw new Error(`Printer ${job.printerId} not found`);

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
                    device = new Network(ip, parseInt(port) || 9100);
                } else if (printerConfig.type === 'usb') {
                    // Native USB detection/printing requires correct VID/PID
                    // This is a stub for native USB. In real-world, use 'escpos-usb' with vendor IDs
                    // Example: [0x04bf, 0x01a1]
                    device = new USB();
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
                if (err) return reject(err);

                // If sending raw hex/base64
                if (data.type === 'raw') {
                    const buffer = Buffer.from(data.content, 'base64');
                    printer
                        .raw(buffer)
                        .close();
                    resolve();
                } else if (data.type === 'text') {
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
