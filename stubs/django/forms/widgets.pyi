# pyre-unsafe

import datetime
from typing import Any, Dict, Optional

class Widget:
    needs_multipart_form: bool = ...
    is_localized: bool = ...
    is_required: bool = ...
    supports_microseconds: bool = ...
    def __init__(self, attrs: Optional[Dict[str, Any]] = ...) -> None: ...

class Input(Widget):
    input_type: str = ...
    template_name: str = ...

CheckboxInput = Input
EmailInput = Input
TextInput = Input
NumberInput = Input
URLInput = Input
HiddenInput = Input
