import json
import os
import unittest
from unittest.mock import Mock, patch

from serial_emqx_bridge.main import publish
from serial_emqx_bridge.parser import parse_frame


class PublishTests(unittest.TestCase):
    def test_publishes_validated_metrics_to_requested_raw_topic(self):
        payload = parse_frame("BG,TEMP:+00238,ZD:00695,XFW:02524,COD:00972,AD:01982,JY:03299,ED")
        client = Mock()
        with patch.dict(os.environ, {}, clear=True):
            publish(client, payload)
        args, kwargs = client.publish.call_args
        self.assertEqual(args[0], "water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_04/telemetry")
        self.assertEqual(json.loads(args[1]), {"watert": 23.8, "turbidity": 69.5, "ss": 252.4, "cod": 97.2, "amnitro": 19.82})
        self.assertEqual(kwargs["qos"], 1)
        client.publish.return_value.wait_for_publish.assert_called_once_with()
