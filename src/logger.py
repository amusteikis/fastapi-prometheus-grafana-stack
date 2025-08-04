from loguru import logger
import sys

logger.remove()  # Remove the default logger
logger.add(sys.stdout, level="INFO", format="{time} | {level} | {message}")
