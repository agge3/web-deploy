import logging
import sys
import os
from datetime import date


LOG_DIR = os.environ.get('LOG_DIR', 'secrets/logs')

class MyLogger(logging.Logger):
    """
    Default:
        TRACE - INFO (+CRITICAL): STDOUT
        WARNING+: STDERR
        INFO+: LOG FILE
    """

    TRACE = 5
    logging.addLevelName(TRACE, "TRACE")
    def trace(self, msg, *args, **kwargs):
        if self.isEnabledFor(self.TRACE):
            self._log(self.TRACE, msg, args, **kwargs)

    @staticmethod
    def create(name=__name__):
        """
        Construct a fully configured MyLogger instance.
        """

        # Ensure getLogger returns MyLogger instances
        logging.setLoggerClass(MyLogger)

        logger = logging.getLogger(name)
        logger.setLevel(MyLogger.TRACE)

        # Prevent duplicate handler attaching
        if not logger.handlers:
            # log format:
            fmt = logging.Formatter(
                "%(name)s | %(asctime)s | %(levelname)s | "
                "%(filename)s[%(process)d]:%(funcName)s:%(lineno)d | "
                "%(message)s"
            )

            # stdout handler
            stdout_handler = logging.StreamHandler(stream=sys.stdout)
            stdout_handler.setFormatter(fmt)
            # filter to uphold stdout conventions: <=INFO +CRITICAL
            stdout_handler.addFilter(
                lambda rec: rec.levelno <= logging.INFO or rec.levelno == logging.CRITICAL
            )
            logger.addHandler(stdout_handler)

            # stderr handler
            stderr_handler = logging.StreamHandler(stream=sys.stderr)
            stderr_handler.setFormatter(fmt)
            stderr_handler.setLevel(logging.WARNING)
            logger.addHandler(stderr_handler)

            # file handler
            my_date = date.today().isoformat()
            os.makedirs(LOG_DIR, exist_ok=True)
            file_handler = logging.FileHandler(f"{LOG_DIR}/{name}-{my_date}.log")
            file_handler.setFormatter(fmt)
            file_handler.setLevel(logging.INFO)

        return logger

# exc_info=True ensures that a Traceback is included
#logger.error(e, exc_info=True)
