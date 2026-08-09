import Link from "next/link";

export default function PoliticaDePrivacidade() {
  return (
    <main className="privacy-page">
      <article className="panel privacy-card">
        <p className="eyebrow">Gabriel e Alanna</p>
        <h1>Política de Privacidade</h1>
        <p>Esta política explica como os dados informados no site do casamento são utilizados.</p>
        <h2>Dados tratados</h2>
        <p>Podemos tratar nome, e-mail, confirmação de presença, informações dos presentes e, quando a regra de valor definida pela administração for atingida, CPF.</p>
        <h2>Finalidade do CPF</h2>
        <p>O CPF é solicitado exclusivamente para identificar contribuições realizadas pelo Mercado Pago e apoiar controles e eventuais obrigações fiscais. A solicitação somente aparece quando o recolhimento está ativado e a soma dos pagamentos aprovados com o pagamento atual alcança o valor mínimo configurado.</p>
        <h2>Proteção e acesso</h2>
        <p>O CPF é validado, armazenado de forma criptografada e não fica disponível publicamente. O acesso administrativo é restrito. Credenciais de pagamento e números completos de CPF não são expostos no navegador.</p>
        <h2>Compartilhamento</h2>
        <p>Os dados necessários à transação são enviados ao Mercado Pago para processar o pagamento. Também poderão ser utilizados para atender uma obrigação legal ou fiscal.</p>
        <h2>Retenção e direitos</h2>
        <p>Os dados serão conservados apenas pelo período necessário às finalidades informadas e aos prazos legais aplicáveis. Solicitações de acesso, correção ou esclarecimento podem ser encaminhadas aos responsáveis pelo casamento.</p>
        <p><small>Versão vigente: 31 de julho de 2026.</small></p>
        <Link className="secondary privacy-back" href="/">Voltar ao site</Link>
      </article>
    </main>
  );
}
