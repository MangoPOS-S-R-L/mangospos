/// Etapa visible del cobro, para que el cajero sepa QUE se esta esperando.
///
/// Existe porque desde que entro la emision e-CF el cobro dejo de ser
/// instantaneo: `emit-document` corre en modo sincrono y puede tardar hasta
/// 8 segundos esperando el codigo de seguridad de la DGII, que es lo que
/// permite imprimir el QR exigido por la Norma 01-2020. Con un spinner mudo
/// esos segundos se leen como que la app se colgo, y el cajero vuelve a
/// tocar Cobrar.
///
/// Vive en `core/fiscal` y no dentro de un modulo de presentacion porque hay
/// dos flujos de cobro distintos que la consumen: el modal simple
/// (`presentation/payments`) y el de split por mesa
/// (`presentation/sales/payment_split_*`). Tenerla en uno de los dos obligaba
/// al otro a importar hacia adentro de un modulo hermano.
enum PaymentStage {
  /// Nada en vuelo.
  idle,

  /// RPC `process_payment`: se registra el pago y se emite el NCF.
  registrando,

  /// `emit-document`: se firma y se envia el e-CF. Solo ocurre en
  /// comprobantes electronicos (Exx); los NCF de papel saltan esta etapa.
  dgii,

  /// El comprobante se despacho a la impresora.
  imprimiendo,

  /// Cobro terminado: todo verde y el NCF a la vista.
  ///
  /// No es decorativo. Sin este estado el modal se cierra en el mismo frame
  /// en que termina de imprimir, asi que el cajero nunca llega a ver que la
  /// emision cerro bien — solo ve el modal desaparecer, que es identico a lo
  /// que veria si algo hubiera fallado. Se sostiene ~1.2s y cierra solo.
  listo,
}
