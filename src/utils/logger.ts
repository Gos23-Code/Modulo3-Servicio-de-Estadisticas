export interface LogData {
  [key: string]: any;
}

const logger = {
  info: (message: string, data: LogData = {}): void => {
    console.log(JSON.stringify({
      level: 'INFO',
      timestamp: new Date().toISOString(),
      message,
      ...data
    }));
  },
  
  error: (message: string, error: Error | LogData = {}): void => {
    const errorData = error instanceof Error 
      ? { error: error.message, stack: error.stack }
      : { error };
      
    console.error(JSON.stringify({
      level: 'ERROR',
      timestamp: new Date().toISOString(),
      message,
      ...errorData
    }));
  },
  
  warn: (message: string, data: LogData = {}): void => {
    console.warn(JSON.stringify({
      level: 'WARN',
      timestamp: new Date().toISOString(),
      message,
      ...data
    }));
  }
};

export default logger;
