import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_uploader_binding.dart';

void main() {
  test('stable Hub destination does not replace an active uploader', () {
    final binding = HubUploaderBinding();
    expect(
      binding.shouldBind(
        businessId: 'biz',
        mode: TerminalMode.hubClient,
        url: 'http://10.0.0.2:4100',
      ),
      isTrue,
    );
    expect(
      binding.shouldBind(
        businessId: 'biz',
        mode: TerminalMode.hubClient,
        url: 'http://10.0.0.2:4100',
      ),
      isFalse,
    );
  });

  test('rebinds immediately when destination, business or mode changes', () {
    final binding = HubUploaderBinding();
    expect(
      binding.shouldBind(
        businessId: 'biz',
        mode: TerminalMode.hubClient,
        url: 'http://10.0.0.2:4100',
      ),
      isTrue,
    );
    expect(
      binding.shouldBind(
        businessId: 'biz',
        mode: TerminalMode.hubClient,
        url: 'http://10.0.0.3:4100',
      ),
      isTrue,
    );
    expect(
      binding.shouldBind(
        businessId: 'other',
        mode: TerminalMode.hubClient,
        url: 'http://10.0.0.3:4100',
      ),
      isTrue,
    );
    expect(
      binding.shouldBind(businessId: 'other', mode: TerminalMode.solo),
      isTrue,
    );
    expect(
      binding.shouldBind(businessId: 'other', mode: TerminalMode.solo),
      isFalse,
    );
    binding.reset();
    expect(
      binding.shouldBind(businessId: 'other', mode: TerminalMode.hubHost),
      isTrue,
    );
  });
}
